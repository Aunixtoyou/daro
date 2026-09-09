@echo off
setlocal EnableDelayedExpansion

rem daro Windows installer build script (Inno Setup 6)
rem Usage:   installer\windows\build_installer.bat [options]
rem Options: -Arch x64^|arm64^|all
rem            Which Windows architecture(s) to package. Default: the host machine's
rem            arch (or every existing build output when -SkipBuild is given).
rem            Flutter desktop supports x64 and arm64 ONLY - there is NO 32-bit x86
rem            target, and arm64 can only be BUILT on an arm64 Windows host. To ship
rem            an arm64 installer from a different machine, run "flutter build windows
rem            --release" there, copy build\windows\arm64\... here, then package with
rem            -SkipBuild -Arch all.
rem          -SkipBuild   skip "flutter build windows --release" (package what is there)
rem          -NoPause     do not wait for a key press on exit (for CI / scripts)
rem          Output: dist\daro-Setup-<version>-<arch>.exe (one file per architecture)
rem Note:    set ISCC_PATH=<full path of ISCC.exe> if installed at a custom location.

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "PROJECT_ROOT=%%~fI"
for %%I in ("%PROJECT_ROOT%\..") do set "PROJECT_ROOT=%%~fI"
set "ISS_FILE=%SCRIPT_DIR%installer.iss"

rem ---------- args ----------
set "SKIP_BUILD="
set "NO_PAUSE="
set "ARCH_REQ="
:parse_args
if "%~1"=="" goto :parse_args_done
if /i "%~1"=="-SkipBuild" ( set "SKIP_BUILD=1" & shift & goto :parse_args )
if /i "%~1"=="-NoPause"   ( set "NO_PAUSE=1"   & shift & goto :parse_args )
if /i "%~1"=="-Arch" (
    if "%~2"=="" (
        echo ERROR: -Arch needs a value: x64, arm64 or all.
        goto :die
    )
    set "ARCH_REQ=%~2"
    shift
    shift
    goto :parse_args
)
echo ERROR: unknown option "%~1"
echo Usage: build_installer.bat [-Arch x64^|arm64^|all] [-SkipBuild] [-NoPause]
goto :die
:parse_args_done

rem ---------- 0. Version: pubspec.yaml is the single source of truth ----------
rem tool\gen_version.py derives two committed files from pubspec.yaml:
rem   lib\app\version.g.dart         (in-app About dialog)
rem   installer\windows\version.inc  (this .iss; GUI compiles read it too)
rem When Python is on PATH we regenerate them here; when it is not, we only verify
rem and refuse to package a stale version. There is deliberately NO fallback
rem default version - silently packing the wrong number is what broke releases.
set "PYEXE="
python -c "import sys" >nul 2>nul && set "PYEXE=python"
if not defined PYEXE (
    py -c "import sys" >nul 2>nul && set "PYEXE=py"
)
if not defined PYEXE goto :version_verify
"%PYEXE%" "%PROJECT_ROOT%\tool\gen_version.py" >nul 2>nul
if errorlevel 1 (
    echo ERROR: tool\gen_version.py failed - check the "version:" line in pubspec.yaml.
    goto :die
)

:version_verify
set "APP_VERSION="
for /f "usebackq tokens=1,2 delims=: " %%a in ("%PROJECT_ROOT%\pubspec.yaml") do (
    if "%%a"=="version" for /f "delims=+" %%v in ("%%b") do set "APP_VERSION=%%v"
)
if not defined APP_VERSION (
    echo ERROR: no "version: x.y.z+n" line found in pubspec.yaml.
    goto :die
)
rem read back  #define PubAppVersion "x.y.z"  from the generated include
set "INC_VERSION="
for /f "usebackq tokens=2,3" %%a in ("%SCRIPT_DIR%version.inc") do (
    if "%%a"=="PubAppVersion" set "INC_VERSION=%%~b"
)
if not "%INC_VERSION%"=="%APP_VERSION%" (
    echo ERROR: installer\windows\version.inc says "%INC_VERSION%" but pubspec.yaml says %APP_VERSION%.
    echo        Python was not found on PATH, so this script could not regenerate it.
    echo        Run:  python tool\gen_version.py    then commit the generated files.
    goto :die
)
findstr /c:"kAppVersion = '%APP_VERSION%'" "%PROJECT_ROOT%\lib\app\version.g.dart" >nul
if errorlevel 1 (
    echo ERROR: lib\app\version.g.dart does not match pubspec.yaml version %APP_VERSION%.
    echo        Run:  python tool\gen_version.py    then commit the generated files.
    goto :die
)
echo App version (from pubspec.yaml): %APP_VERSION%

rem ---------- 1. Check Inno Setup (fail fast before flutter build) ----------
call :locate_iscc
if not defined ISCC goto :no_innosetup
echo Inno Setup found: !ISCC!

rem ---------- 2. Host architecture + which arch(s) to package ----------
set "HOST_ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "HOST_ARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "HOST_ARCH=arm64"
echo Host architecture: %HOST_ARCH%

set "ARCH_LIST="
if /i "%ARCH_REQ%"=="all"   set "ARCH_LIST=x64 arm64"
if /i "%ARCH_REQ%"=="x64"   set "ARCH_LIST=x64"
if /i "%ARCH_REQ%"=="arm64" set "ARCH_LIST=arm64"
if defined ARCH_REQ if not defined ARCH_LIST (
    echo ERROR: unsupported -Arch "%ARCH_REQ%".  Valid: x64, arm64, all.
    echo        Flutter desktop has no 32-bit x86 target, and arm64 can only be
    echo        built on an arm64 Windows host.
    goto :die
)
if defined ARCH_LIST goto :resolve_build
rem auto mode: with -SkipBuild package every existing output; otherwise just the host arch
if defined SKIP_BUILD ( set "ARCH_LIST=x64 arm64" ) else ( set "ARCH_LIST=%HOST_ARCH%" )

:resolve_build
rem ---------- 3. Flutter release build (only the host arch can be built on this machine) ----------
set "RUN_BUILD="
if defined SKIP_BUILD goto :pkg_loop
for %%A in (%ARCH_LIST%) do if /i "%%A"=="%HOST_ARCH%" set "RUN_BUILD=1"
if not defined RUN_BUILD (
    echo NOTE: no build requested for %HOST_ARCH%; packaging prebuilt output only.
    goto :pkg_loop
)
echo ==^> flutter build windows --release  (arch: %HOST_ARCH%) ...
pushd "%PROJECT_ROOT%"
call flutter build windows --release -v
if errorlevel 1 (
    popd
    echo ERROR: flutter build failed. Close the running app if the linker could not
    echo        overwrite the exe ^(LNK1168^), then re-run this script.
    goto :die
)
popd

:pkg_loop
rem ---------- 4. Package each requested architecture ----------
set "N_PKG=0"
set "HARD_FAIL="
for %%A in (%ARCH_LIST%) do call :package_arch %%A
if defined HARD_FAIL goto :die
if not "!N_PKG!"=="0" goto :pkg_done
echo ERROR: no installer was produced. Build the target architecture first
echo        ^(flutter build windows --release^), then re-run this script.
goto :die

:pkg_done
echo.
echo Done. Wrote !N_PKG! installer(s) to %PROJECT_ROOT%\dist
dir /b "%PROJECT_ROOT%\dist\daro-Setup-*.exe"
call :maybe_pause
endlocal
exit /b 0

rem ============================================================
rem  Subroutine: package one architecture (%1 = x64 | arm64)
rem ============================================================
:package_arch
set "ARCH=%~1"
set "PBD=%PROJECT_ROOT%\build\windows\%ARCH%\runner\Release"
if exist "%PBD%\daro.exe" goto :pa_run
rem --- build output for this arch is not present ---
if /i "%ARCH_REQ%"=="%ARCH%" (
    echo ERROR: build output not found: %PBD%\daro.exe
    echo        Build it on a %ARCH% machine with "flutter build windows --release",
    echo        copy the output here, then re-run with -SkipBuild.
    set "HARD_FAIL=1"
) else (
    echo Skip %ARCH%: no build output under build\windows\%ARCH%
)
goto :eof
:pa_run
set "PA_EXTRA="
if /i "%ARCH%"=="arm64" set "PA_EXTRA=/DIsArm64"
set "ISCC_ARGS="%ISS_FILE%" /DMyAppVersion=%APP_VERSION% /DArchTarget=%ARCH% /DBuildDir="%PBD%" !PA_EXTRA!"
echo ==^> packaging %ARCH%: "!ISCC!" !ISCC_ARGS!
"!ISCC!" !ISCC_ARGS!
if errorlevel 1 (
    echo ERROR: ISCC compile failed for %ARCH%.
    set "HARD_FAIL=1"
    goto :eof
)
set /a N_PKG+=1
goto :eof

rem ============================================================
rem  Abort: print a footer, keep the window open when double-clicked
rem ============================================================
:die
echo.
echo Build aborted.
call :maybe_pause
endlocal
exit /b 1

rem A double-clicked .bat closes its console the moment the script ends, which
rem turns any error into an unreadable flash. Wait for a key press unless -NoPause
rem was given (CI) - with a redirected stdin, pause returns immediately anyway.
:maybe_pause
if defined NO_PAUSE goto :eof
pause
goto :eof

rem ============================================================
rem  Subroutine: locate ISCC.exe
rem  Order: ISCC_PATH env -^> PATH -^> common dirs -^> registry
rem ============================================================
:locate_iscc
set "ISCC="

rem 1) explicit override
if defined ISCC_PATH if exist "%ISCC_PATH%" (
    set "ISCC=%ISCC_PATH%"
    goto :eof
)

rem 2) on PATH
for /f "delims=" %%i in ('where iscc.exe 2^>nul') do if not defined ISCC set "ISCC=%%i"
if defined ISCC goto :eof

rem 3) common install directories
for %%P in (
    "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
    "%ProgramFiles%\Inno Setup 6\ISCC.exe"
    "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    "C:\Program Files\Inno Setup 6\ISCC.exe"
    "D:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    "D:\Program Files\Inno Setup 6\ISCC.exe"
) do if not defined ISCC if exist %%P set "ISCC=%%~P"
if defined ISCC goto :eof

rem 4) uninstall registry entries (incl. 32-bit view on 64-bit Windows)
for %%R in (
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
    "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
) do (
    if not defined ISCC for /f "tokens=2,*" %%a in ('reg query %%R /v InstallLocation 2^>nul ^| findstr /i "InstallLocation"') do (
        if exist "%%bISCC.exe" set "ISCC=%%bISCC.exe"
    )
)
goto :eof

rem ============================================================
rem  Inno Setup not found: print install instructions
rem ============================================================
:no_innosetup
echo.
echo ============================================================
echo  ERROR: Inno Setup 6 not found (ISCC.exe missing).
echo ============================================================
echo.
echo  Option 1 (recommended): install via winget
echo      winget install JRSoftware.InnoSetup
echo.
echo  Option 2: download the official installer
echo      https://jrsoftware.org/isdl.php
echo      (run innosetup-6.x.x.exe, default install path is fine)
echo.
echo  Option 3: already installed at a custom location?
echo      set "ISCC_PATH=^<full path of ISCC.exe^>"
echo      then re-run this script.
echo.
echo  After installing, open a NEW terminal and re-run:
echo      installer\windows\build_installer.bat
echo ============================================================
echo.
call :maybe_pause
endlocal
exit /b 1

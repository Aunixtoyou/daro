; daro Windows 安装脚本（Inno Setup 6）
; 编译方式：
;   1) 图形界面：用 Inno Setup Compiler 打开本文件后按 F9（需先 flutter build）
;   2) 命令行：  & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\windows\installer.iss
;   3) 一键：    installer\windows\build_installer.bat（推荐：自动读版本、先 build 再打包）
;
; 命令行可选参数（通过 ISCC /DName=Value 传入）：
;   /DMyAppVersion=1.2.3   覆盖版本号（build_installer.bat 会从 pubspec.yaml 自动传入）
;   /DArchTarget=x64|arm64   目标架构（默认 x64），决定构建产物目录与安装包文件名后缀
;   /DIsArm64                标记为 arm64 包（bat 打 arm64 时传入，配合 Inno 6.3 的 arm64 模式）
;   /DBuildDir="X:\abs\path\to\Release"   覆盖构建产物目录（bat 会传对应架构的绝对路径）

; ---- 版本号与路径 ----
; 版本的唯一数据源是 pubspec.yaml 的 version:,由 tool/gen_version.py 生成同目录下的
; version.inc(随仓库提交)。build_installer.bat 每次打包前会先重新生成它。
; 命令行 /DMyAppVersion=x.y.z 仍可显式覆盖(仅用于临时试包)。
#include "version.inc"
#ifndef MyAppVersion
  #define MyAppVersion PubAppVersion
#endif
; 目标架构：x64（默认）或 arm64。bat 通过 /DArchTarget 传入；GUI 直接编译时按 x64。
#ifndef ArchTarget
  #define ArchTarget "x64"
#endif
#ifndef BuildDir
  ; 相对本 .iss 文件（installer/windows/），回退到对应架构的 Flutter 标准输出目录
  #define BuildDir "..\..\build\windows\" + ArchTarget + "\runner\Release"
#endif

#define MyAppName "daro"
#define MyAppPublisher "com.example"
#define MyAppExeName "daro.exe"

; ---- 编译期校验：缺失构建产物直接报错（不会把错误带进安装包运行时） ----
; 注意：Raise() 仅适用于较新版本的 ISPP；旧版请用 build_installer.bat（bat 已做构建产物检查）
#if !FileExists(BuildDir + "\" + MyAppExeName)
  #if !Defined(SkipBuildCheck)
    #error 未找到构建产物，请先执行 flutter build windows --release 或运行 build_installer.bat
  #endif
#endif

[Setup]
; AppId 用于升级识别，发布后请勿修改
AppId={{8F5C2A9E-4D1B-4B6E-9C3A-2F7D5B9E0A11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
; 安装包自身 exe 的版本属性(资源管理器→属性→详细信息),否则 FileVersion 为空
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
; 允许用户选择"为所有用户"或"仅为当前用户"安装
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; 安装界面语言：简体中文 + 英文
ShowLanguageDialog=yes
; OutputDir 相对本 .iss 文件 -> 项目根目录下 dist\
OutputDir=..\..\dist
; 命名与其他平台产物对齐：daro-<版本>-<平台>-<架构>（macOS 为 daro-<版本>-macos-universal.dmg，
; Linux 为 daro-<版本>-linux-<架构>.deb/.tar.xz），不再使用早期的 daro-Setup-<版本>-<架构>
OutputBaseFilename={#MyAppName}-{#MyAppVersion}-windows-{#ArchTarget}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 64 位安装模式按目标架构切换（arm64 需 Inno Setup 6.3+；bat 打 arm64 时传 /DIsArm64）
#ifdef IsArm64
ArchitecturesInstallIn64BitMode=arm64
ArchitecturesAllowed=arm64
#else
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; 安装/卸载信息写入"应用和功能"
DisableWelcomePage=no
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; 简体中文：优先项目本地副本，其次 Inno Setup 安装目录；都没有则仅英文
#define ZhIsl ""
#if FileExists(".\languages\ChineseSimplified.isl")
  #define ZhIsl ".\languages\ChineseSimplified.isl"
#elif FileExists("compiler:Languages\ChineseSimplified.isl")
  #define ZhIsl "compiler:Languages\ChineseSimplified.isl"
#endif
#if ZhIsl != ""
Name: "chinesesimplified"; MessagesFile: "{#ZhIsl}"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 打包整个 release 输出目录（含 exe、flutter dll、插件 dll、sqlite3.dll、data 目录等）
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

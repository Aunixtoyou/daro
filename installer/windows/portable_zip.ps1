# daro Windows portable (green/zip) packer.
#
# Called by installer\windows\build_installer.bat (-Portable / -All). Not meant to be
# run by hand, but it is self-contained if you need to.
#
# Result layout - one versioned top level folder, so unzipping next to an existing
# install never scatters files into the user's Downloads folder:
#
#   daro-<version>-windows-<arch>\
#     daro.exe
#     flutter_windows.dll
#     data\...
#     LICENSE / NOTICE.md        (GPLv3 requires the license text to ship with the binary)
#
# Why not Compress-Archive:
#   * it cannot set the top level folder name inside the archive - it either flattens
#     everything or prefixes the randomly named staging dir;
#   * it is noticeably slower and buffers more memory on multi-hundred-file trees.
# So we write entries straight through the .NET ZipFile API instead (streamed, keeps
# file timestamps, no temp directory to clean up).

[CmdletBinding()]
param(
    # Flutter build output dir, e.g. build\windows\x64\runner\Release
    [Parameter(Mandatory = $true)][string]$Source,

    # Full path of the .zip to write
    [Parameter(Mandatory = $true)][string]$Output,

    # Top level folder name inside the archive, e.g. daro-0.3.1-windows-x64
    [Parameter(Mandatory = $true)][string]$RootName,

    # Extra files copied into the archive root (LICENSE, NOTICE.md, ...). Semicolon
    # separated list - a real [string[]] parameter cannot be filled reliably through
    # "powershell.exe -File" (repeating -ExtraFile is a binding error, and "a","b" is
    # passed as one literal token), so we split it ourselves. Missing entries only
    # warn - a doc change must never fail a release build.
    [string]$ExtraFiles = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 (the powershell.exe on CI) does not preload the compression
# types, and they are split across two assemblies: ZipFile / ZipFileExtensions live in
# System.IO.Compression.FileSystem, ZipArchiveMode / CompressionLevel in
# System.IO.Compression. Loading only the first makes ZipArchiveMode unresolvable.
# Both calls are idempotent on PowerShell 7.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "source directory not found: $Source"
}
$exe = Join-Path $Source 'daro.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "daro.exe not found under: $Source  (run: flutter build windows --release)"
}

$outputDir = Split-Path -Parent -Path $Output
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$prefix = $RootName.TrimEnd('\', '/')
$sourceFull = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')

if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }

$files = @(Get-ChildItem -LiteralPath $sourceFull -Recurse -File -Force)
if ($files.Count -eq 0) { throw "source directory is empty: $Source" }

$count = 0
$zip = [System.IO.Compression.ZipFile]::Open($Output, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($sourceFull.Length).TrimStart('\', '/')
        # Zip entries always use '/' - a backslash would become literal in the file name.
        $entryName = "$prefix/" + ($rel -replace '\\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $f.FullName, $entryName,
            [System.IO.Compression.CompressionLevel]::Optimal)
        $count++
    }

    foreach ($extra in ($ExtraFiles -split ';')) {
        if ([string]::IsNullOrWhiteSpace($extra)) { continue }
        $extra = $extra.Trim()
        if (-not (Test-Path -LiteralPath $extra -PathType Leaf)) {
            Write-Warning "extra file not found, skipped: $extra"
            continue
        }
        $leaf = Split-Path -Leaf -Path $extra
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, (Resolve-Path -LiteralPath $extra).Path, "$prefix/$leaf",
            [System.IO.Compression.CompressionLevel]::Optimal)
        $count++
        Write-Host "  + $prefix/$leaf"
    }
}
finally {
    $zip.Dispose()
}

if (-not (Test-Path -LiteralPath $Output)) { throw "archive was not created: $Output" }

$size = [math]::Round(((Get-Item -LiteralPath $Output).Length / 1MB), 2)
Write-Host ("portable: {0}  ({1} entries, {2} MB)" -f (Split-Path -Leaf -Path $Output), $count, $size)

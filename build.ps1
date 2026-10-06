# Builds Photo Organizer for Windows (C# / WPF, WindowsApp\) and installs it for the current user.
#
#   .\build.ps1          build and install into %LOCALAPPDATA%\Programs\PhotoOrganizer (restarts a running copy)
#   .\build.ps1 -Zip     also write dist\PhotoOrganizer-Windows-v<version>.zip for a release
#
# $env:INSTALL_DIR = "D:\Apps\PhotoOrganizer"; .\build.ps1   installs somewhere else.
# Needs the .NET 10 SDK (https://dot.net). The macOS app is built with build.sh.
param([switch]$Zip)
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Version = (Get-Content (Join-Path $Root "VERSION") -Raw).Trim()
$Project = Join-Path $Root "WindowsApp\PhotoOrganizer\PhotoOrganizer.csproj"
$Dest = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\PhotoOrganizer" }
$Exe = Join-Path $Dest "PhotoOrganizer.exe"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

if (-not ((& dotnet --list-sdks 2>$null) -match "^10\.")) {
    Write-Error "The .NET 10 SDK is needed: https://dot.net"
}

# Build outside the project, so no bin\ or obj\ folders are left in it.
$Out = Join-Path ([IO.Path]::GetTempPath()) ("photoorganizer-" + [guid]::NewGuid())
$App = Join-Path $Out "PhotoOrganizer"
try {
    Write-Host "Building Photo Organizer $Version..."
    # One self-contained exe: no .NET needed on the user's PC; the native parts (ONNX Runtime, DirectML, WebView2's
    # loader) are unpacked next to it on first start.
    & dotnet publish $Project -c Release -r win-x64 --self-contained true -o $App --artifacts-path (Join-Path $Out "artifacts") `
        --nologo -v quiet -p:Version=$Version -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:EnableCompressionInSingleFile=true -p:DebugType=none
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    # Debug symbols, API docs and import libraries the packages bring along: not needed to run.
    Get-ChildItem $App -Include *.pdb, *.xml, *.lib -Recurse | Remove-Item -Force

    if ($Zip) {
        $Dist = Join-Path $Root "dist"
        New-Item -ItemType Directory -Force $Dist | Out-Null
        $ZipFile = Join-Path $Dist "PhotoOrganizer-Windows-v$Version.zip"
        Remove-Item $ZipFile -Force -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $App "*") -DestinationPath $ZipFile
        Write-Host "Release zip: $ZipFile"
    }

    # Close a running copy first; if it stays open (a move in progress), leave the installed version alone.
    $running = @(Get-Process PhotoOrganizer -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe })
    if ($running) {
        Write-Host "Closing the running Photo Organizer..."
        $running | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        $running | ForEach-Object { $_.WaitForExit(10000) | Out-Null }
        if (Get-Process PhotoOrganizer -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe }) {
            Write-Error "Photo Organizer is still running. Close it and run the build again."
        }
    }

    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force $Dest | Out-Null
    Copy-Item -Recurse (Join-Path $App "*") $Dest
    Write-Host "Installed: $Exe"
    if ($running) { Start-Process $Exe }
}
finally {
    Remove-Item -Recurse -Force $Out -ErrorAction SilentlyContinue
}

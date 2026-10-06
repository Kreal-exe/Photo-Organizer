# Builds Photo Organizer for Windows (C# / WPF, WindowsApp\).
#
#   .\build.ps1          build\PhotoOrganizer-Windows\PhotoOrganizer.exe, put on the Desktop
#   .\build.ps1 run      build and start the app
#   .\build.ps1 clean    delete the Windows build output
#
# Needs the .NET 10 SDK; when it is missing it is installed for the current user (no administrator rights) into
# %LOCALAPPDATA%\Microsoft\dotnet. The macOS app is built with build.sh. Releases are built by GitHub Actions
# (.github/workflows/release.yml) on every push to main.
param([string]$Command = "build")
# Native tools write progress to stderr, which Windows PowerShell would treat as a failure: exit codes are checked instead.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

# VERSION holds major.minor; a release adds its build number, a local build ".0".
$Version = if ($env:VERSION) { $env:VERSION } else { "$((Get-Content (Join-Path $PSScriptRoot "VERSION")).Trim()).0" }
$Project = Join-Path $PSScriptRoot "WindowsApp\PhotoOrganizer\PhotoOrganizer.csproj"
$Output = Join-Path $PSScriptRoot "build"
$App = Join-Path $Output "PhotoOrganizer-Windows"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

function Find-Dotnet {
    foreach ($candidate in @((Get-Command dotnet -ErrorAction SilentlyContinue).Source,
                             (Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"))) {
        if ($candidate -and (Test-Path $candidate)) {
            $sdks = & $candidate --list-sdks 2>$null
            if ($sdks -match "^10\.") { return $candidate }
        }
    }
    Write-Host "Installing the .NET 10 SDK for this user..."
    $installer = Join-Path $env:TEMP "dotnet-install.ps1"
    Invoke-WebRequest https://dot.net/v1/dotnet-install.ps1 -OutFile $installer -UseBasicParsing
    $directory = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet"
    & $installer -Channel 10.0 -InstallDir $directory | Out-Null
    return Join-Path $directory "dotnet.exe"
}

$Dotnet = Find-Dotnet
# The app built here finds this .NET when run from the build folder.
$env:DOTNET_ROOT = Split-Path $Dotnet

function Publish {
    $exe = Join-Path $App "PhotoOrganizer.exe"
    if (Get-Process PhotoOrganizer -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
        Write-Host "Photo Organizer is running from $App - close it and build again."
        exit 1
    }
    Remove-Item -Recurse -Force $App -ErrorAction SilentlyContinue
    # One self-contained exe: no .NET needed on the user's PC; the native parts (ONNX Runtime, DirectML, WebView2's
    # loader) are unpacked next to it on first start.
    & $Dotnet publish $Project -c Release -r win-x64 --self-contained true -o $App --nologo -v quiet `
        -p:Version=$Version -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:EnableCompressionInSingleFile=true -p:DebugType=none
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    # Debug symbols, API docs and import libraries the packages bring along: not needed to run.
    Get-ChildItem $App -Include *.pdb, *.xml, *.lib -Recurse | Remove-Item -Force
}

switch ($Command) {
    "run" {
        & $Dotnet build $Project -c Debug --nologo -v quiet
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        & $Dotnet run --project $Project -c Debug --no-build
    }
    "clean" {
        Remove-Item -Recurse -Force $App -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $PSScriptRoot "WindowsApp") -Directory -Recurse -Include bin, obj | Remove-Item -Recurse -Force
        Write-Host "Removed the Windows build output"
    }
    "build" {
        Publish
        # The app goes on the Desktop; only its own files there are replaced.
        $Desktop = [Environment]::GetFolderPath("Desktop")
        Copy-Item -Recurse -Force (Join-Path $App "*") $Desktop
        Write-Host "Built $Desktop\PhotoOrganizer.exe (version $Version)"
    }
    default { Get-Content $PSCommandPath -TotalCount 9 | Select-Object -Skip 1; exit 1 }
}

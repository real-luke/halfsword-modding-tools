<# :
@echo off
set "SCRIPT_DIR=%~dp0"
set "UE4SS_FORCE_DEV=0"

if /i "%~1"=="-dev" set "UE4SS_FORCE_DEV=1"
if /i "%~1"=="--dev" set "UE4SS_FORCE_DEV=1"

echo %~dp0 | findstr /i "Temp" >nul
if %errorlevel%==0 (
    echo [ERROR] It looks like you are running this from a ZIP file.
    echo Please EXTRACT the files to a folder before running this script.
    pause
    exit /b
)

net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo [!] This script may need Admin rights depending on where your game is installed.
    echo [!] If it fails, close this, right-click the .bat, and 'Run as Administrator'.
    timeout /t 2 >nul
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression (Get-Content '%~f0' -Raw)"
exit /b
#>

# =====================================================================
# POWERSHELL LOGIC STARTS HERE
# =====================================================================

Write-Host "`nLocating Half Sword..." -ForegroundColor Cyan
$GameDir = $null
$ScriptDir = $env:SCRIPT_DIR
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $PSCommandPath
}

$SteamRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2397300",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2397300"
)

foreach ($SteamReg in $SteamRegPaths) {
    $GameDir = (Get-ItemProperty -Path $SteamReg -ErrorAction SilentlyContinue).InstallLocation
    if ($GameDir -and (Test-Path $GameDir)) {
        break
    }
}

if (-not $GameDir -or -not (Test-Path $GameDir)) {
    $EpicManifestPath = "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path $EpicManifestPath) {
        $Manifests = Get-ChildItem $EpicManifestPath -Filter "*.item"
        foreach ($File in $Manifests) {
            $Content = Get-Content $File.FullName | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($Content.DisplayName -like "*Half Sword*") {
                $GameDir = $Content.InstallLocation
                break
            }
        }
    }
}

if (-not $GameDir -or -not (Test-Path $GameDir)) {
    Write-Host "Could not find game automatically." -ForegroundColor Yellow
    $RawPath = Read-Host "Please paste your 'Half Sword' folder path"
    $GameDir = $RawPath.Trim('"')
}

# --- DIRECTORY SETUP ---
$TargetBinaries = Join-Path $GameDir "HalfswordUE5\Binaries\Win64"
$Ue4ssFolder = Join-Path $TargetBinaries "ue4ss"
$ModsFolder = Join-Path $Ue4ssFolder "Mods"
$PaksFolder = Join-Path $GameDir "HalfswordUE5\Content\Paks"

if (-not (Test-Path $TargetBinaries)) {
    Write-Error "Invalid path! Path not found: $TargetBinaries"
    Read-Host "Press Enter to exit"
    exit 1
}

# --- UE4SS INSTALLATION LOGIC ---
$DoInstall = $true
if (Test-Path $Ue4ssFolder) {
    Write-Host "`nExisting ue4ss installation found." -ForegroundColor Yellow
    $Response = Read-Host "Would you like to Reinstall/Update to the latest experimental release? (Y/N)"
    if ($Response -notmatch "^[Yy]$") { $DoInstall = $false }
}

if ($DoInstall) {
    try {
        $ApiUrl = "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest"
        $Release = Invoke-RestMethod -Uri $ApiUrl -Headers @{ "User-Agent" = "halfsword-autoinstall" }

        $InstallType = "Normal"
        $DocsFolder = Join-Path $Ue4ssFolder "Docs"
        $ForceDevInstall = ($env:UE4SS_FORCE_DEV -eq "1")

        if ($ForceDevInstall) {
            $InstallType = "Developer"
            Write-Host "Developer install requested via launch flag." -ForegroundColor DarkCyan
        } elseif ((Test-Path $Ue4ssFolder) -and (Test-Path $DocsFolder)) {
            $InstallType = "Developer"
            Write-Host "Keeping existing Developer UE4SS install." -ForegroundColor DarkCyan
        }

        if ($InstallType -eq "Developer") {
            $Asset = $Release.assets | Where-Object { $_.name -like "zDEV-UE4SS*.zip" } | Select-Object -First 1
        } else {
            $Asset = $Release.assets | Where-Object { $_.name -like "UE4SS*.zip" -and $_.name -notlike "*zDEV*" } | Select-Object -First 1
        }

        if (-not $Asset) {
            throw "No $InstallType UE4SS zip asset found in experimental-latest release."
        }
        $ZipPath = Join-Path $env:TEMP "UE4SS_Temp.zip"
        
        Write-Host "Downloading and installing UE4SS..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipPath
        Expand-Archive -Path $ZipPath -DestinationPath $TargetBinaries -Force
        Remove-Item $ZipPath -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "UE4SS download/install failed: $($_.Exception.Message)"
        Write-Warning "Moving to mod installation."
    }
}

# --- LUA MOD INSTALLATION ---
Write-Host "`nScanning for UE4SS Lua mods..." -ForegroundColor Cyan

$PotentialMods = Get-ChildItem -Path $ScriptDir -Directory
$ValidModsFound = @()

foreach ($Dir in $PotentialMods) {
    $HasScripts = Test-Path (Join-Path $Dir.FullName "Scripts")
    $HasEnabled = Test-Path (Join-Path $Dir.FullName "enabled.txt")
    
    if ($HasScripts -or $HasEnabled) {
        $ValidModsFound += $Dir
    }
}

$LuaModsInstalled = $false
if ($ValidModsFound.Count -gt 0) {
    if (-not (Test-Path $ModsFolder)) { New-Item -Path $ModsFolder -ItemType Directory -Force | Out-Null }
    
    foreach ($Mod in $ValidModsFound) {
        Write-Host "Installing Lua mod: $($Mod.Name)" -ForegroundColor Green
        Copy-Item -Path $Mod.FullName -Destination $ModsFolder -Recurse -Force
        $LuaModsInstalled = $true
    }
}

# --- PAK FILE INSTALLATION ---
Write-Host "`nScanning for .pak mods..." -ForegroundColor Cyan

$PakFiles = Get-ChildItem -Path $ScriptDir -Filter "*.pak" -File
$PaksInstalled = $false

if ($PakFiles.Count -gt 0) {
    if (-not (Test-Path $PaksFolder)) { New-Item -Path $PaksFolder -ItemType Directory -Force | Out-Null }
    
    foreach ($Pak in $PakFiles) {
        Write-Host "Installing Pak: $($Pak.Name)" -ForegroundColor Green
        Copy-Item -Path $Pak.FullName -Destination $PaksFolder -Force
        $PaksInstalled = $true
    }
}

# --- FINALIZE ---
Write-Host "`nSetup complete!" -ForegroundColor Magenta

if (-not $LuaModsInstalled -and -not $PaksInstalled) {
    Write-Host "Opening UE4SS Mods folder so you can add mods manually..." -ForegroundColor Gray
    if (-not (Test-Path $ModsFolder)) { New-Item -Path $ModsFolder -ItemType Directory -Force | Out-Null }
    explorer.exe $ModsFolder
}

Read-Host "`nPress Enter to exit"
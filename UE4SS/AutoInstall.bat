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
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression (Get-Content '%~f0' -Raw)"
exit /b
#>

# =====================================================================
# POWERSHELL LOGIC STARTS HERE
# =====================================================================

Write-Host "Locating Half Sword..." -ForegroundColor Cyan
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
    # Fallback for Steam installs where app uninstall keys are missing.
    $SteamRoots = @(
        (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath,
        (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath,
        (Get-ItemProperty -Path "HKLM:\SOFTWARE\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath,
        (Join-Path ${env:ProgramFiles(x86)} "Steam"),
        (Join-Path $env:ProgramFiles "Steam")
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($SteamRoot in $SteamRoots) {
        $Candidate = Join-Path $SteamRoot "steamapps\common\Half Sword"
        if (Test-Path $Candidate) {
            $GameDir = $Candidate
            break
        }
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

$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$ProtectedRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:windir) | Where-Object { $_ }
$NeedsAdminHint = $false
foreach ($Root in $ProtectedRoots) {
    if ($GameDir.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $NeedsAdminHint = $true
        break
    }
}

if ($NeedsAdminHint -and -not $IsAdmin) {
    Write-Host "`n[!] Your game appears to be in a protected Windows folder." -ForegroundColor DarkGray
    Write-Host "[!] If install steps fail, close this, right-click the .bat, and 'Run as Administrator'." -ForegroundColor DarkGray
}

# --- UE4SS INSTALLATION LOGIC ---
$EnhancerPath = Join-Path $env:APPDATA "Half Sword Enhancer"
$EnhancerFolderExists = Test-Path $EnhancerPath
$DwmapiProxyPath = Join-Path $TargetBinaries "dwmapi.dll"
$HasUe4ssFolder = Test-Path $Ue4ssFolder
$ManualEnhancerDetected = $EnhancerFolderExists -and (Test-Path $DwmapiProxyPath) -and -not $HasUe4ssFolder

$DoInstall = $true
$SkipLuaInstall = $false
$Ue4ssInstalled = $false

if ($ManualEnhancerDetected) {
    Write-Host "`nHalf Sword Enhancer manual install detected." -ForegroundColor Yellow
    Write-Host "Skipping UE4SS and Lua mod installation to avoid conflicts." -ForegroundColor Yellow
    $DoInstall = $false
    $SkipLuaInstall = $true
} elseif ($EnhancerFolderExists -and -not $HasUe4ssFolder) {
    Write-Host "`nHalf Sword Enhancer folder detected." -ForegroundColor Yellow
    $EnhancerResponse = Read-Host "Install UE4SS anyway? This may conflict with Half Sword Enhancer. (Y/N)"
    if ($EnhancerResponse -notmatch "^[Yy]$") {
        Write-Host "Skipping UE4SS and Lua mod installation." -ForegroundColor Yellow
        $DoInstall = $false
        $SkipLuaInstall = $true
    }
}

if ($DoInstall -and $HasUe4ssFolder) {
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
        $Ue4ssInstalled = $true
    } catch {
        Write-Warning "UE4SS download/install failed: $($_.Exception.Message)"
        Write-Warning "Moving to mod installation."
    }
}

# --- LUA MOD INSTALLATION ---
if (-not $SkipLuaInstall) {
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
            $DestinationModPath = Join-Path $ModsFolder $Mod.Name
            if (Test-Path $DestinationModPath) {
                Remove-Item -Recurse -Force $DestinationModPath
            }
            Move-Item -Path $Mod.FullName -Destination $ModsFolder -Force
            $LuaModsInstalled = $true
        }
    }
} else {
    $LuaModsInstalled = $false
}

# --- PAK FILE INSTALLATION ---
Write-Host "`nScanning for .pak mods..." -ForegroundColor Cyan

$PakFiles = Get-ChildItem -Path $ScriptDir -Filter "*.pak" -File
$PaksInstalled = $false

if ($PakFiles.Count -gt 0) {
    if (-not (Test-Path $PaksFolder)) { New-Item -Path $PaksFolder -ItemType Directory -Force | Out-Null }
    
    foreach ($Pak in $PakFiles) {
        Write-Host "Installing Pak: $($Pak.Name)" -ForegroundColor Green
        Move-Item -Path $Pak.FullName -Destination $PaksFolder -Force
        $PaksInstalled = $true
    }
}

# --- FINALIZE ---
Write-Host "`nSetup complete!" -ForegroundColor Magenta

if (-not $Ue4ssInstalled -and -not $LuaModsInstalled -and -not $PaksInstalled) {
    if ($SkipLuaInstall) {
        Write-Host "`nOpening Paks folder for manual installation..." -ForegroundColor Gray
        if (-not (Test-Path $PaksFolder)) { New-Item -Path $PaksFolder -ItemType Directory -Force | Out-Null }
        explorer.exe $PaksFolder
    } else {
        Write-Host "`nOpening mod folders for manual installation..." -ForegroundColor Gray
        if (-not (Test-Path $ModsFolder)) { New-Item -Path $ModsFolder -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $PaksFolder)) { New-Item -Path $PaksFolder -ItemType Directory -Force | Out-Null }
        explorer.exe $ModsFolder
        explorer.exe $PaksFolder
    }
}

Read-Host "`nPress Enter to exit"
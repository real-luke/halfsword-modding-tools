<# :
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:SCRIPT_FILE='%~f0'; Invoke-Expression (Get-Content '%~f0' -Raw)"
exit /b
#>

# =====================================================================
# POWERSHELL LOGIC STARTS HERE
# =====================================================================

$ToolsDir = Join-Path $env:LOCALAPPDATA "HalfSwordModTools"
$CfgPath = Join-Path $ToolsDir "paths.ini"
$ScriptDir = Split-Path -Parent $env:SCRIPT_FILE

# Load Config if exists
$Config = @{}
if (Test-Path $CfgPath) {
    Get-Content $CfgPath | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            $Config[$matches[1]] = $matches[2]
        }
    }
}

# Need to look for uproject where the script actually is, just like %~dp0
$UProject = Get-ChildItem -Path (Join-Path $ScriptDir "\*.uproject") -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $UProject) {
    $UProject = Get-ChildItem -Path ".\*.uproject" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $UProject) {
    Write-Host "[!] No .uproject found here." -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}
$UProjectPath = $UProject.FullName

$EngineDir = $Config["ENGINE_DIR"]

# Try to find EngineDir in registry if missing or invalid
if (-not $EngineDir -or -not (Test-Path (Join-Path $EngineDir "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"))) {
    $EngineDir = $null
    $RegPaths = @(
        "HKLM:\SOFTWARE\EpicGames\Unreal Engine\5.4",
        "HKCU:\SOFTWARE\EpicGames\Unreal Engine\5.4"
    )
    foreach ($RegPath in $RegPaths) {
        $InstallDir = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).InstalledDirectory
        if ($InstallDir -and (Test-Path (Join-Path $InstallDir "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"))) {
            $EngineDir = $InstallDir
            break
        }
    }
}

# Ask user if still not found
if (-not $EngineDir) {
    $EngineDir = Read-Host "Paste your UE 5.4 folder (e.g., C:\Program Files\Epic Games\UE_5.4)"
    if ($EngineDir) { $EngineDir = $EngineDir.Trim('"') }
}

$EditorCmd = Join-Path $EngineDir "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
if (-not (Test-Path $EditorCmd)) {
    Write-Host "[!] Invalid Engine path." -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

# Save paths back to config
if (-not (Test-Path $ToolsDir)) {
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
}

$Config["ENGINE_DIR"] = $EngineDir
$CfgContent = @()
$Config.GetEnumerator() | ForEach-Object {
    $CfgContent += "$($_.Name)=$($_.Value)"
}
$CfgContent | Set-Content $CfgPath

Write-Host "Fixing redirectors..." -ForegroundColor Cyan
& $EditorCmd $UProjectPath -run=ResavePackages -fixupredirects -projectonly -unattended -stdout -NoLogTimes

Write-Host "`nCooking project..." -ForegroundColor Cyan
& $EditorCmd $UProjectPath -run=cook -targetplatform=Windows -unversioned -projectonly "-CookDir=/Game/Mods+/Game/CustomMaps" "-ini:Game:[/Script/UnrealEd.ProjectPackagingSettings]:bShareMaterialShaderCode=False" "-ini:Game:[/Script/UnrealEd.ProjectPackagingSettings]:bSharedMaterialNativeLibraries=False" -stdout -NoLogTimes -iterate

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[!] Cook FAILED with exit code $LASTEXITCODE" -ForegroundColor Red
    Write-Host "Please check the output above for details; packaging may still work." -ForegroundColor Yellow
} else {
    Write-Host "`nFinished cooking!" -ForegroundColor Green
}

Write-Host "Press Enter to exit..."
Read-Host

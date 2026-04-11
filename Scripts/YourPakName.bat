<# :
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:SCRIPT_FILE='%~f0'; $env:SCRIPT_ARGS='%*'; Invoke-Expression (Get-Content '%~f0' -Raw)"
exit /b
#>

# =====================================================================
# POWERSHELL LOGIC STARTS HERE
# =====================================================================

$ToolsDir = Join-Path $env:LOCALAPPDATA "HalfSwordModTools"
$CfgPath = Join-Path $ToolsDir "paths.ini"
$ScriptDir = Split-Path -Parent $env:SCRIPT_FILE

$BatName = [System.IO.Path]::GetFileNameWithoutExtension($env:SCRIPT_FILE)
$Src = Join-Path $ScriptDir "Saved\Cooked\Windows"
if (-not (Test-Path $Src)) { $Src = Join-Path $ScriptDir "..\Saved\Cooked\Windows" }
$PakName = $BatName

# Handle drag-and-drop arguments (folder or file path)
if ($env:SCRIPT_ARGS -and $env:SCRIPT_ARGS.Trim() -ne "") {
    $Arg = $env:SCRIPT_ARGS.Trim()
    if ($Arg.StartsWith("`"") -and $Arg.EndsWith("`"") -and $Arg.Length -gt 1) {
        $Arg = $Arg.Substring(1, $Arg.Length - 2)
    }
    if ($Arg) {
        $Src = $Arg
        $PakName = [System.IO.Path]::GetFileName($Src)
    }
}

if (Test-Path $Src) {
    $Src = (Resolve-Path $Src).Path
} else {
    Write-Host "[!] Source missing: $Src" -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

# Load Config
$Config = @{}
if (Test-Path $CfgPath) {
    Get-Content $CfgPath | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            $Config[$matches[1]] = $matches[2]
        }
    }
}

$GameDir = $Config["GAME_DIR"]

# Try to find game directory via registry if it's missing or invalid
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir "HalfswordUE5\Content\Paks"))) {
    $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2397300"
    $GameDir = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).InstallLocation
}

# Ask user if still not found
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir "HalfswordUE5\Content\Paks"))) {
    $GameDir = Read-Host "Paste 'Half Sword' folder (e.g., C:\Steam\steamapps\common\Half Sword)"
    if ($GameDir) { $GameDir = $GameDir.Trim('"') }
}

$PaksDir = Join-Path $GameDir "HalfswordUE5\Content\Paks"
if (-not (Test-Path $PaksDir)) {
    Write-Host "[!] Invalid Half Sword folder - Paks directory not found." -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

# Save paths back to config
if (-not (Test-Path $ToolsDir)) {
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
}
$Config["GAME_DIR"] = $GameDir
$CfgContent = @()
$Config.GetEnumerator() | ForEach-Object {
    if ($_.Value) { $CfgContent += "$($_.Name)=$($_.Value)" }
}
$CfgContent | Set-Content $CfgPath

# Resolve repak dependencies
$RepakExe = Join-Path $ToolsDir "repak.exe"
$OodleDll = Join-Path $ToolsDir "oo2core_9_win64.dll"

$LocalRepak = Join-Path $ScriptDir "..\Binaries\repak.exe"
if (-not (Test-Path $LocalRepak)) { $LocalRepak = Join-Path $ScriptDir "repak.exe" }
if (-not (Test-Path $LocalRepak)) { $LocalRepak = Join-Path $ScriptDir "Binaries\repak.exe" }
if (Test-Path $LocalRepak) { Copy-Item -Path (Resolve-Path $LocalRepak).Path -Destination $RepakExe -Force }

$LocalOodle = Join-Path $ScriptDir "..\Binaries\oo2core_9_win64.dll"
if (-not (Test-Path $LocalOodle)) { $LocalOodle = Join-Path $ScriptDir "oo2core_9_win64.dll" }
if (-not (Test-Path $LocalOodle)) { $LocalOodle = Join-Path $ScriptDir "Binaries\oo2core_9_win64.dll" }
if (Test-Path $LocalOodle) { Copy-Item -Path (Resolve-Path $LocalOodle).Path -Destination $OodleDll -Force }

$RepakCmd = "repak"
$RepakMode = "PATH"

if (Test-Path $RepakExe) {
    $RepakCmd = $RepakExe
    $RepakMode = "BUNDLED"
} else {
    if (-not (Get-Command "repak" -ErrorAction SilentlyContinue)) {
        Write-Host "[!] repak.exe not found in $ToolsDir and not found in PATH." -ForegroundColor Red
        Write-Host "[!] Put repak.exe next to this script or install repak using their installer." -ForegroundColor Yellow
        Write-Host "Press Enter to exit..."
        Read-Host
        exit 1
    }
}

if ($RepakMode -eq "BUNDLED") {
    Write-Host "Using bundled repak." -ForegroundColor Cyan
}

# Cleanup unnecessary files
if ($Src -match "Saved[\\/]Cooked[\\/]Windows$") {
    Write-Host "Cleaning shaders and engine files..." -ForegroundColor Gray
    $EngineDirToRemove = Join-Path $Src "Engine"
    if (Test-Path $EngineDirToRemove) {
        Remove-Item -Recurse -Force $EngineDirToRemove -ErrorAction SilentlyContinue
    }
    
    $FilesToRemove = @(
        "HalfswordUE5\Content\ShaderAssetInfo-Global*.*",
        "HalfswordUE5\Content\ShaderArchive-Global*.*",
        "HalfswordUE5\Metadata\ShaderLibrarySource\ShaderAssetInfo-Global*.*",
        "HalfswordUE5\Metadata\ShaderLibrarySource\ShaderArchive-Global*.*"
    )
    
    foreach ($FilePattern in $FilesToRemove) {
        $PathToRemove = Join-Path $Src $FilePattern
        Get-ChildItem $PathToRemove -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

$PakDest = Join-Path $PaksDir "$PakName.pak"
Write-Host "`nPackaging $PakName.pak..." -ForegroundColor Cyan

$RepakExit = 0
if ($RepakMode -eq "BUNDLED") {
    Push-Location $ToolsDir
    & $RepakCmd pack $Src $PakDest
    $RepakExit = $LASTEXITCODE
    Pop-Location
} else {
    & $RepakCmd pack $Src $PakDest
    $RepakExit = $LASTEXITCODE
}

if ($RepakExit -ne 0) {
    Write-Host "`n[!] Packaging failed." -ForegroundColor Red
} else {
    Write-Host "`nDone!" -ForegroundColor Green
}

Write-Host "Press Enter to exit..."
Read-Host

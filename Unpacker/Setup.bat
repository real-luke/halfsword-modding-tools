<# :
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:SCRIPT_FILE='%~f0'; Invoke-Expression (Get-Content '%~f0' -Raw)"
exit /b
#>

# =====================================================================
# POWERSHELL LOGIC STARTS HERE
# =====================================================================

$ScriptDir = Split-Path -Parent $env:SCRIPT_FILE
$ToolsDir = Join-Path $env:LOCALAPPDATA "HalfSwordModTools"
$CfgPath = Join-Path $ToolsDir "paths.ini"
$AesKey = "0xBCBF7B45A4A8150D06F7B955BC25EF5CE603470F508302CAD0EB48FEA2D91517"
$PakName = "pakchunk0-Windows.pak"

# Load saved paths
$Config = @{}
if (Test-Path $CfgPath) {
    Get-Content $CfgPath | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            $Config[$matches[1]] = $matches[2]
        }
    }
}

$GameDir = $Config["GAME_DIR"]
if (-not $GameDir -or -not (Test-Path $GameDir)) {
    $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2397300"
    $GameDir = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).InstallLocation
}

if (-not $GameDir -or -not (Test-Path $GameDir)) {
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

$SourceDir = $Config["SOURCE_DIR"]
if (-not $SourceDir) { $SourceDir = "C:\HalfSwordSource" }

$PromptSource = Read-Host "Where would you like to put the unpacked source (leave blank for $SourceDir)"
if ($PromptSource -and $PromptSource.Trim() -ne "") {
    $SourceDir = $PromptSource.Trim('"')
}

if (-not ($SourceDir -match "^[A-Za-z]:\\[^<>|?*]+$") -or $SourceDir.Length -le 3) {
    Write-Host "[!] SOURCE_DIR must be an absolute valid folder path like C:\HalfSwordSource" -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

if ($SourceDir.TrimEnd('\') -eq $GameDir.TrimEnd('\')) {
    Write-Host "[!] SOURCE_DIR cannot be the game install folder." -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

if (-not (Test-Path $SourceDir)) {
    try {
        New-Item -ItemType Directory -Path $SourceDir -Force -ErrorAction Stop | Out-Null
        Remove-Item -Recurse -Force $SourceDir | Out-Null
    } catch {
        Write-Host "[!] SOURCE_DIR could not be created: $SourceDir" -ForegroundColor Red
        Write-Host "[!] Choose a writable folder path and run Setup.bat again." -ForegroundColor Yellow
        Write-Host "Press Enter to exit..."
        Read-Host
        exit 1
    }
}

if (Test-Path $SourceDir) {
    Write-Host "`n[!] $SourceDir already exists." -ForegroundColor Yellow
    Write-Host "    This could be a partial or outdated unpack. It will be deleted and replaced." -ForegroundColor Gray
    $Choice = Read-Host "Delete it and do a fresh unpack? (Y/N)"
    if ($Choice -notmatch "^[Yy]$") {
        Write-Host "Setup cancelled." -ForegroundColor Yellow
        Write-Host "Press Enter to exit..."
        Read-Host
        exit 1
    }
}

if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
$Config["GAME_DIR"] = $GameDir
$Config["SOURCE_DIR"] = $SourceDir
$CfgContent = @()
$Config.GetEnumerator() | Sort-Object Name | ForEach-Object {
    if ($_.Value) { $CfgContent += "$($_.Name)=$($_.Value)" }
}
$CfgContent | Set-Content $CfgPath

$RepakExe = Join-Path $ToolsDir "repak.exe"
$OodleDll = Join-Path $ToolsDir "oo2core_9_win64.dll"

$LocalRepak = Join-Path $ScriptDir "..\Binaries\repak.exe"
if (-not (Test-Path $LocalRepak)) { $LocalRepak = Join-Path $ScriptDir "repak.exe" }
if (Test-Path $LocalRepak) { Copy-Item -Path (Resolve-Path $LocalRepak).Path -Destination $RepakExe -Force }

$LocalOodle = Join-Path $ScriptDir "..\Binaries\oo2core_9_win64.dll"
if (-not (Test-Path $LocalOodle)) { $LocalOodle = Join-Path $ScriptDir "oo2core_9_win64.dll" }
if (Test-Path $LocalOodle) { Copy-Item -Path (Resolve-Path $LocalOodle).Path -Destination $OodleDll -Force }

$RepakCmd = "repak"
$RepakMode = "PATH"

if (Test-Path $RepakExe) {
    $RepakCmd = $RepakExe
    $RepakMode = "BUNDLED"
} else {
    if (-not (Get-Command "repak" -ErrorAction SilentlyContinue)) {
        Write-Host "[!] repak.exe not found in $ToolsDir and not found in PATH." -ForegroundColor Red
        Write-Host "[!] Put repak.exe (and oo2core_9_win64.dll) in the Binaries folder next to this script." -ForegroundColor Yellow
        Write-Host "Press Enter to exit..."
        Read-Host
        exit 1
    }
}

if ($RepakMode -eq "BUNDLED") {
    Write-Host "Using bundled repak." -ForegroundColor Cyan
    if (-not (Test-Path $OodleDll)) {
        Write-Host "[!] Warning: oo2core_9_win64.dll not found - unpack may fail on Oodle-compressed assets." -ForegroundColor DarkYellow
    }
} else {
    Write-Host "Using repak from PATH (no bundled repak found)." -ForegroundColor Yellow
}

$PakPath = Join-Path $PaksDir $PakName
$RepakOut = Join-Path $PaksDir "pakchunk0-Windows"

if (-not (Test-Path $PakPath)) {
    Write-Host "[!] Could not find $PakPath" -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

if (Test-Path $RepakOut) {
    Write-Host "Removing leftover unpack folder from Paks..." -ForegroundColor Gray
    Remove-Item -Recurse -Force $RepakOut -ErrorAction SilentlyContinue
    if (Test-Path $RepakOut) {
        Write-Host "[!] Could not delete: $RepakOut" -ForegroundColor Red
        Write-Host "[!] Close any Explorer or editor windows that may have it open, then run Setup.bat again." -ForegroundColor Yellow
        Write-Host "Press Enter to exit..."
        Read-Host
        exit 1
    }
}

Write-Host "Unpacking $PakName..." -ForegroundColor Cyan
$RepakExit = 0
if ($RepakMode -eq "BUNDLED") {
    Push-Location $ToolsDir
    & $RepakCmd --aes-key $AesKey unpack $PakPath
    $RepakExit = $LASTEXITCODE
    Pop-Location
} else {
    & $RepakCmd --aes-key $AesKey unpack $PakPath
    $RepakExit = $LASTEXITCODE
}

if ($RepakExit -ne 0) {
    Write-Host "[!] repak exited with code $RepakExit - unpack did not complete." -ForegroundColor Red
    if (Test-Path $RepakOut) {
        Write-Host "    Cleaning up partial output..." -ForegroundColor Gray
        Remove-Item -Recurse -Force $RepakOut -ErrorAction SilentlyContinue
    }
    Write-Host "[!] If you saw `"Oodle initialization failed`", make sure oo2core_9_win64.dll is in the Binaries folder." -ForegroundColor Yellow
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

if (-not (Test-Path $RepakOut)) {
    Write-Host "[!] Unpack appeared to succeed but output folder was not found: $RepakOut" -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

if (Test-Path $SourceDir) {
    Write-Host "Removing existing source directory..." -ForegroundColor Gray
    Remove-Item -Recurse -Force $SourceDir -ErrorAction SilentlyContinue
    if (Test-Path $SourceDir) {
        Write-Host "[!] Could not delete: $SourceDir" -ForegroundColor Red
        Write-Host "[!] Close any Explorer or editor windows that may have it open, then run Setup.bat again." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $RepakOut -ErrorAction SilentlyContinue
        Write-Host "Press Enter to exit..."
        Read-Host
        exit 1
    }
}

Write-Host "Moving unpacked files to $SourceDir..." -ForegroundColor Cyan
Move-Item -Path $RepakOut -Destination $SourceDir -Force

if (-not (Test-Path $SourceDir)) {
    Write-Host "[!] Move failed." -ForegroundColor Red
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}

$UnpackDir = $SourceDir
$UnpackEngineDir = Join-Path $UnpackDir "Engine"
if (Test-Path $UnpackEngineDir) {
    Write-Host "Removing Engine folder..." -ForegroundColor Gray
    Remove-Item -Recurse -Force $UnpackEngineDir -ErrorAction SilentlyContinue
}

$UprojectSrc = Join-Path $ScriptDir "HalfswordUE5.uproject"
$UprojectDest = Join-Path $UnpackDir "HalfswordUE5\HalfswordUE5.uproject"
if (Test-Path $UprojectSrc) {
    Write-Host "Copying pre-configured .uproject..." -ForegroundColor Cyan
    Copy-Item -Path $UprojectSrc -Destination $UprojectDest -Force
}

$BinariesSrc = Join-Path $ScriptDir "Binaries"
$BinariesDest = Join-Path $UnpackDir "HalfswordUE5\Binaries"
if (Test-Path $BinariesSrc) {
    Write-Host "Copying Binaries..." -ForegroundColor Cyan
    Copy-Item -Path $BinariesSrc -Destination $BinariesDest -Recurse -Force
}

$SourceCodeSrc = Join-Path $ScriptDir "Source"
$SourceCodeDest = Join-Path $UnpackDir "HalfswordUE5\Source"
if (Test-Path $SourceCodeSrc) {
    Write-Host "Copying Source folder..." -ForegroundColor Cyan
    Copy-Item -Path $SourceCodeSrc -Destination $SourceCodeDest -Recurse -Force
}

$SuzieSrc = Join-Path $ScriptDir "Plugins\Suzie"
$SuzieDest = Join-Path $UnpackDir "HalfswordUE5\Plugins\Suzie"
if (Test-Path $SuzieSrc) {
    Write-Host "Copying Suzie plugin..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path (Split-Path $SuzieDest -Parent) -Force | Out-Null
    Copy-Item -Path $SuzieSrc -Destination $SuzieDest -Recurse -Force
}

$JmapSrc = Join-Path $ScriptDir "Content\DynamicClasses\output.jmap"
$JmapDestDir = Join-Path $UnpackDir "HalfswordUE5\Content\DynamicClasses"
if (Test-Path $JmapSrc) {
    Write-Host "Copying output.jmap..." -ForegroundColor Cyan
    if (-not (Test-Path $JmapDestDir)) { New-Item -ItemType Directory -Path $JmapDestDir -Force | Out-Null }
    Copy-Item -Path $JmapSrc -Destination (Join-Path $JmapDestDir "output.jmap") -Force
}

$BatScripts = @("Cook.bat", "YourPakName.bat")
foreach ($Bat in $BatScripts) {
    $TargetBatDest = Join-Path $UnpackDir ("HalfswordUE5\" + $Bat)
    $BatSrcScript = Join-Path $ScriptDir ("..\Scripts\" + $Bat)
    if (-not (Test-Path $BatSrcScript)) { $BatSrcScript = Join-Path $ScriptDir ("..\Batch\" + $Bat) }
    
    if (Test-Path $BatSrcScript) {
        Write-Host "Copying $Bat to project..." -ForegroundColor Cyan
        Copy-Item -Path (Resolve-Path $BatSrcScript).Path -Destination $TargetBatDest -Force
    }
}

$HairDir = Join-Path $UnpackDir "HalfswordUE5\Content\MetaHumans\Taro\MaleHair\Hair"
$HairFiles = Join-Path $HairDir "Hair_M_SideSweptFringe.*"
if (Test-Path $HairDir) {
    Write-Host "Removing crash-causing hair files..." -ForegroundColor Gray
    Remove-Item -Path $HairFiles -Force -ErrorAction SilentlyContinue
}

$ContentDir = Join-Path $UnpackDir "HalfswordUE5\Content"
$ConfigDir = Join-Path $UnpackDir "HalfswordUE5\Config"
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }

$DefaultGame = Join-Path $ConfigDir "DefaultGame.ini"
Write-Host "Writing DefaultGame.ini..." -ForegroundColor Cyan
$GameIniContent = @()
if (Test-Path $DefaultGame) {
    $InPps = $false
    Get-Content $DefaultGame | ForEach-Object {
        if ($_.StartsWith("[")) { $InPps = $false }
        if ($_ -eq "[/Script/UnrealEd.ProjectPackagingSettings]") { $InPps = $true }
        if (-not $InPps) { $GameIniContent += $_ }
    }
}
$GameIniContent += ""
$GameIniContent += "[/Script/UnrealEd.ProjectPackagingSettings]"
$GameIniContent += "bSkipEditorContent=True"
if (Test-Path $ContentDir) {
    Get-ChildItem $ContentDir -Directory | ForEach-Object {
        $GameIniContent += "+DirectoriesToNeverCook=(Path=`"/Game/$($_.Name)`")"
    }
}
$GameIniContent | Set-Content $DefaultGame

$DefaultEngine = Join-Path $ConfigDir "DefaultEngine.ini"
$EngineIniContent = @()
if (Test-Path $DefaultEngine) {
    $InCooker = $false
    Get-Content $DefaultEngine | ForEach-Object {
        if ($_.StartsWith("[")) { $InCooker = $false }
        if ($_ -eq "[/Script/UnrealEd.CookerSettings]" -or $_ -eq "[Core.System]") { $InCooker = $true }
        if (-not $InCooker -and -not ($_ -match "^\s*GlobalDefaultGameMode\s*=")) { $EngineIniContent += $_ }
    }
}
$EngineIniContent += ""
$EngineIniContent += "[/Script/UnrealEd.CookerSettings]"
$EngineIniContent += "cook.AllowCookedDataInEditorBuilds=True"
$EngineIniContent += "s.AllowUnversionedContentInEditor=1"
$EngineIniContent += ""
$EngineIniContent += "[Core.System]"
$EngineIniContent += "CanUseUnversionedPropertySerialization=True"
$EngineIniContent += ""
$EngineIniContent += "[/Script/EngineSettings.GameMapsSettings]"
$EngineIniContent += "GlobalDefaultGameMode="
$EngineIniContent | Set-Content $DefaultEngine

$DefaultEditor = Join-Path $ConfigDir "DefaultEditor.ini"
$EditorIniContent = @()
if (Test-Path $DefaultEditor) {
    $InCookSet = $false
    Get-Content $DefaultEditor | ForEach-Object {
        if ($_.StartsWith("[")) { $InCookSet = $false }
        if ($_ -eq "[CookSettings]") { $InCookSet = $true }
        if (-not $InCookSet) { $EditorIniContent += $_ }
    }
}
$EditorIniContent += ""
$EditorIniContent += "[CookSettings]"
$EditorIniContent += "CookContentMissingSeverity=Warning"
$EditorIniContent | Set-Content $DefaultEditor

Write-Host "`nSetup complete!" -ForegroundColor Magenta
Write-Host "Unpacked project is at: $(Join-Path $SourceDir 'HalfswordUE5')" -ForegroundColor Green
Write-Host ""
explorer.exe (Join-Path $SourceDir 'HalfswordUE5')

Write-Host "Press Enter to exit..."
Read-Host

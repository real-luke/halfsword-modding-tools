@echo off
setlocal enabledelayedexpansion

set "TOOLS_DIR=%LOCALAPPDATA%\HalfSwordModTools"
set "CFG=!TOOLS_DIR!\paths.ini"
set "SRC=Saved\Cooked\Windows"
set "PAK_NAME=%~n0"

if not "%~1"=="" (set "SRC=%~1" & set "PAK_NAME=%~n1")
if not exist "!SRC!" echo [!] Source missing & pause & exit /b

if exist "%CFG%" (
    for /f "tokens=1,2 delims==" %%A in ("%CFG%") do set "%%A=%%B"
)

if not exist "!GAME_DIR!" (
    for /f "tokens=2*" %%A in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2397300" /v "InstallLocation" 2^>nul') do (
        set "GAME_DIR=%%B"
    )
)

if not exist "!GAME_DIR!" (
    set /p GAME_DIR="Paste 'Half Sword' folder (e.g., C:\Steam\steamapps\common\Half Sword): "
    set "GAME_DIR=!GAME_DIR:"=!"
)

set "P_PATH=!GAME_DIR!\HalfswordUE5\Content\Paks"
if not exist "!P_PATH!" echo [!] Invalid Half Sword folder & pause & exit /b

if not exist "!TOOLS_DIR!\" mkdir "!TOOLS_DIR!\"
(
    if defined ENGINE_DIR echo ENGINE_DIR=!ENGINE_DIR!
    echo GAME_DIR=!GAME_DIR!
    if defined SOURCE_DIR echo SOURCE_DIR=!SOURCE_DIR!
) > "%CFG%"

REM === Resolve repak ===
set "REPAK_EXE=!TOOLS_DIR!\repak.exe"
set "OODLE_DLL=!TOOLS_DIR!\oo2core_9_win64.dll"
set "REPAK_CMD=repak"
set "REPAK_MODE=PATH"

if exist "%~dp0repak.exe" (
    copy /Y "%~dp0repak.exe" "!REPAK_EXE!" >nul
)

if exist "%~dp0oo2core_9_win64.dll" (
    copy /Y "%~dp0oo2core_9_win64.dll" "!OODLE_DLL!" >nul
)

if exist "!REPAK_EXE!" (
    set "REPAK_CMD=!REPAK_EXE!"
    set "REPAK_MODE=BUNDLED"
) else (
    where repak >nul 2>&1
    if errorlevel 1 (
        echo [!] repak.exe not found in !TOOLS_DIR! and not found in PATH.
        echo [!] Put repak.exe next to this script or install repak using the installer.
        pause & exit /b
    )
)

if /I "!REPAK_MODE!"=="BUNDLED" (
    echo Using bundled repak from !TOOLS_DIR!.
) else (
    echo Bundled repak unavailable - using repak from PATH.
)

if "!SRC!"=="Saved\Cooked\Windows" (
    echo Cleaning shaders and engine files...
    rmdir /S /Q "!SRC!\Engine" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Content\ShaderAssetInfo-Global*.*" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Content\ShaderArchive-Global*.*" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Metadata\ShaderLibrarySource\ShaderAssetInfo-Global*.*" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Metadata\ShaderLibrarySource\ShaderArchive-Global*.*" >nul 2>&1
)

echo Packaging !PAK_NAME!.pak...
if /I "!REPAK_MODE!"=="BUNDLED" (
    pushd "!TOOLS_DIR!"
    "!REPAK_CMD!" pack "!SRC!" "!P_PATH!\!PAK_NAME!.pak"
    set "REPAK_EXIT=!ERRORLEVEL!"
    popd
) else (
    "!REPAK_CMD!" pack "!SRC!" "!P_PATH!\!PAK_NAME!.pak"
    set "REPAK_EXIT=!ERRORLEVEL!"
)

if not "!REPAK_EXIT!"=="0" (
    echo [!] Packaging failed.
    pause & exit /b
)

echo Done!
pause

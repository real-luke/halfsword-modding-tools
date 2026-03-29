@echo off
setlocal enabledelayedexpansion

set "CFG=%LOCALAPPDATA%\HalfSwordModTools\paths.ini"
set "SRC=Saved\Cooked\Windows"
set "PAK_NAME=%~n0"

if not "%~1"=="" (set "SRC=%~1" & set "PAK_NAME=%~nx1")
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

if not exist "%LOCALAPPDATA%\HalfSwordModTools\" mkdir "%LOCALAPPDATA%\HalfSwordModTools\"
(
    if defined ENGINE_DIR echo ENGINE_DIR=!ENGINE_DIR!
    echo GAME_DIR=!GAME_DIR!
) > "%CFG%"

if "!SRC!"=="Saved\Cooked\Windows" (
    echo Cleaning shaders and engine files...
    rmdir /S /Q "!SRC!\Engine" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Content\ShaderAssetInfo-Global*.*" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Content\ShaderArchive-Global*.*" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Metadata\ShaderLibrarySource\ShaderAssetInfo-Global*.*" >nul 2>&1
    del /Q "!SRC!\HalfswordUE5\Metadata\ShaderLibrarySource\ShaderArchive-Global*.*" >nul 2>&1
)

echo Packaging !PAK_NAME!.pak...
repak pack "!SRC!" "!P_PATH!\!PAK_NAME!.pak"

echo Done!
pause

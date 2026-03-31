@echo off
setlocal enabledelayedexpansion

set "TOOLS_DIR=%LOCALAPPDATA%\HalfSwordModTools"
set "CFG=!TOOLS_DIR!\paths.ini"
set "AES_KEY=0xBCBF7B45A4A8150D06F7B955BC25EF5CE603470F508302CAD0EB48FEA2D91517"
set "PAK=pakchunk0-Windows.pak"

REM === Load saved paths ===
if exist "%CFG%" (
    for /f "tokens=1,2 delims==" %%A in ("%CFG%") do set "%%A=%%B"
)

REM === Find GAME_DIR ===
if not exist "!GAME_DIR!" (
    for /f "tokens=2*" %%A in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2397300" /v "InstallLocation" 2^>nul') do (
        set "GAME_DIR=%%B"
    )
)

if not exist "!GAME_DIR!" (
    set /p GAME_DIR="Paste 'Half Sword' folder (e.g., C:\Steam\steamapps\common\Half Sword): "
    set "GAME_DIR=!GAME_DIR:"=!"
)

set "PAKS_DIR=!GAME_DIR!\HalfswordUE5\Content\Paks"
if not exist "!PAKS_DIR!" (
    echo [!] Invalid Half Sword folder - Paks directory not found.
    pause & exit /b
)

REM === Ask where to put the unpacked source ===
if not defined SOURCE_DIR set "SOURCE_DIR=C:\HalfSwordSource"
set /p "SOURCE_DIR=Where do you want to put the unpacked source folder (leave blank for !SOURCE_DIR!): "
if "!SOURCE_DIR!"=="" set "SOURCE_DIR=C:\HalfSwordSource"
set "SOURCE_DIR=!SOURCE_DIR:"=!"

REM === Save paths ===
if not exist "!TOOLS_DIR!\" mkdir "!TOOLS_DIR!\"
(
    if defined ENGINE_DIR echo ENGINE_DIR=!ENGINE_DIR!
    echo GAME_DIR=!GAME_DIR!
    echo SOURCE_DIR=!SOURCE_DIR!
) > "%CFG%"

REM === Prepare repak ===
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
    if not exist "!OODLE_DLL!" (
        echo [!] Warning: oo2core_9_win64.dll is not in !TOOLS_DIR!; unpack may fail on Oodle-compressed assets.
    )
) else (
    echo Bundled repak unavailable - using repak from PATH.
)

REM === Unpack pak ===
set "PAK_PATH=!PAKS_DIR!\%PAK%"
set "REPAK_OUT=!PAKS_DIR!\pakchunk0-Windows"

if not exist "!PAK_PATH!" (
    echo [!] Could not find !PAK_PATH!
    pause & exit /b
)

if exist "!REPAK_OUT!" (
    echo Found leftover unpack folder at !REPAK_OUT! - deleting it first...
    rmdir /S /Q "!REPAK_OUT!"
    if exist "!REPAK_OUT!" (
        echo [!] Could not delete stale folder: !REPAK_OUT!
        echo [!] Close Explorer/Editor windows using it, then run Setup.bat again.
        pause & exit /b
    )
)

echo Unpacking %PAK%...
if /I "!REPAK_MODE!"=="BUNDLED" (
    pushd "!TOOLS_DIR!"
    "!REPAK_CMD!" --aes-key %AES_KEY% unpack "!PAK_PATH!"
    set "REPAK_EXIT=!ERRORLEVEL!"
    popd
) else (
    "!REPAK_CMD!" --aes-key %AES_KEY% unpack "!PAK_PATH!"
    set "REPAK_EXIT=!ERRORLEVEL!"
)

if not "!REPAK_EXIT!"=="0" (
    echo [!] repak reported an error and unpack did not complete.
    echo [!] If you saw "Oodle initialization failed previously", verify game files and make sure the bundled repak build is up to date.
    pause & exit /b
)

if not exist "!REPAK_OUT!" (
    echo [!] Unpack failed or output folder not found: !REPAK_OUT!
    pause & exit /b
)

REM === Move to SOURCE_DIR ===
if exist "!SOURCE_DIR!" (
    echo [!] !SOURCE_DIR! already exists - delete it first if you want a fresh unpack.
    pause & exit /b
)
echo Moving to !SOURCE_DIR!...
move "!REPAK_OUT!" "!SOURCE_DIR!" >nul
if not exist "!SOURCE_DIR!" (
    echo [!] Move failed.
    pause & exit /b
)
set "UNPACK_DIR=!SOURCE_DIR!"

REM === Remove Engine folder (not needed for modding) ===
if exist "!UNPACK_DIR!\Engine" (
    echo Removing Engine folder...
    rmdir /S /Q "!UNPACK_DIR!\Engine"
)

REM === Overwrite .uproject with pre-configured version ===
if exist "%~dp0HalfswordUE5.uproject" (
    echo Copying pre-configured .uproject...
    copy /Y "%~dp0HalfswordUE5.uproject" "!UNPACK_DIR!\HalfswordUE5\HalfswordUE5.uproject" >nul
) else (
    echo [!] HalfswordUE5.uproject not found next to this script - skipping.
)

REM === Copy Binaries ===
if exist "%~dp0Binaries" (
    echo Copying Binaries...
    xcopy /E /I /Y "%~dp0Binaries" "!UNPACK_DIR!\HalfswordUE5\Binaries" >nul
) else (
    echo [!] Binaries folder not found next to this script - skipping.
)

REM === Copy Source folder (dummied module) ===
if exist "%~dp0Source" (
    echo Copying Source folder...
    xcopy /E /I /Y "%~dp0Source" "!UNPACK_DIR!\HalfswordUE5\Source" >nul
) else (
    echo [!] Source folder not found next to this script - skipping.
)

REM === Copy Suzie plugin ===
if exist "%~dp0Plugins\Suzie" (
    echo Copying Suzie plugin...
    xcopy /E /I /Y "%~dp0Plugins\Suzie" "!UNPACK_DIR!\HalfswordUE5\Plugins\Suzie" >nul
) else (
    echo [!] Plugins\Suzie not found next to this script - skipping.
)

REM === Copy jmap ===
if exist "%~dp0Content\DynamicClasses\output.jmap" (
    echo Copying output.jmap...
    if not exist "!UNPACK_DIR!\HalfswordUE5\Content\DynamicClasses\" mkdir "!UNPACK_DIR!\HalfswordUE5\Content\DynamicClasses\"
    copy /Y "%~dp0Content\DynamicClasses\output.jmap" "!UNPACK_DIR!\HalfswordUE5\Content\DynamicClasses\output.jmap" >nul
) else (
    echo [!] Content\DynamicClasses\output.jmap not found next to this script - skipping.
)

REM === Copy cook and package scripts to project ===
for %%F in (Cook.bat YourPakName.bat) do (
    if exist "%~dp0..\Scripts\%%F" (
        echo Copying %%F to project...
        copy /Y "%~dp0..\Scripts\%%F" "!UNPACK_DIR!\HalfswordUE5\%%F" >nul
    ) else if exist "%~dp0..\Batch\%%F" (
        echo Copying %%F from legacy Batch folder...
        copy /Y "%~dp0..\Batch\%%F" "!UNPACK_DIR!\HalfswordUE5\%%F" >nul
    )
)

REM === Delete crash-causing MetaHuman hair files ===
set "HAIR_DIR=!UNPACK_DIR!\HalfswordUE5\Content\MetaHumans\Taro\MaleHair\Hair"
if exist "!HAIR_DIR!" (
    echo Removing crash-causing hair files...
    del /Q "!HAIR_DIR!\Hair_M_SideSweptFringe.*" >nul 2>&1
)

REM === Write DirectoriesToNeverCook to DefaultGame.ini ===
set "CONTENT_DIR=!UNPACK_DIR!\HalfswordUE5\Content"
set "CONFIG_DIR=!UNPACK_DIR!\HalfswordUE5\Config"
set "DEFAULTGAME=!CONFIG_DIR!\DefaultGame.ini"

if not exist "!CONFIG_DIR!" mkdir "!CONFIG_DIR!"

echo Writing DirectoriesToNeverCook to DefaultGame.ini...

REM Strip any existing ProjectPackagingSettings section to avoid duplicates on re-run
if exist "!DEFAULTGAME!" (
    set "IN_SECTION=0"
    > "!DEFAULTGAME!.tmp" (
        for /f "usebackq delims=" %%L in ("!DEFAULTGAME!") do (
            set "LINE=%%L"
            if "!LINE:~0,1!"=="[" set "IN_SECTION=0"
            if "!LINE!"=="[/Script/UnrealEd.ProjectPackagingSettings]" set "IN_SECTION=1"
            if "!IN_SECTION!"=="0" echo !LINE!
        )
    )
    move /Y "!DEFAULTGAME!.tmp" "!DEFAULTGAME!" >nul
)

REM Append fresh section with all top-level Content folders
(
    echo.
    echo [/Script/UnrealEd.ProjectPackagingSettings]
    echo bSkipEditorContent=True
    for /d %%D in ("!CONTENT_DIR!\*") do echo +DirectoriesToNeverCook=(Path="/Game/%%~nxD"^)
) >> "!DEFAULTGAME!"

REM === Write DefaultEngine.ini ===
set "DEFAULTENGINE=!CONFIG_DIR!\DefaultEngine.ini"
echo Writing DefaultEngine.ini settings...

REM Strip existing sections we're about to write to avoid duplicates
if exist "!DEFAULTENGINE!" (
    set "IN_SECTION=0"
    > "!DEFAULTENGINE!.tmp" (
        for /f "usebackq delims=" %%L in ("!DEFAULTENGINE!") do (
            set "LINE=%%L"
            if "!LINE:~0,1!"=="[" set "IN_SECTION=0"
            if "!LINE!"=="[/Script/UnrealEd.CookerSettings]" set "IN_SECTION=1"
            if "!LINE!"=="[Core.System]" set "IN_SECTION=1"
            if "!IN_SECTION!"=="0" echo !LINE!
        )
    )
    move /Y "!DEFAULTENGINE!.tmp" "!DEFAULTENGINE!" >nul
)

(
    echo.
    echo [/Script/UnrealEd.CookerSettings]
    echo cook.AllowCookedDataInEditorBuilds=True
    echo s.AllowUnversionedContentInEditor=1
    echo.
    echo [Core.System]
    echo CanUseUnversionedPropertySerialization=True
) >> "!DEFAULTENGINE!"

REM === Write DefaultEditor.ini ===
set "DEFAULTEDITOR=!CONFIG_DIR!\DefaultEditor.ini"
echo Writing DefaultEditor.ini settings...

REM Strip existing CookSettings section to avoid duplicates
if exist "!DEFAULTEDITOR!" (
    set "IN_SECTION=0"
    > "!DEFAULTEDITOR!.tmp" (
        for /f "usebackq delims=" %%L in ("!DEFAULTEDITOR!") do (
            set "LINE=%%L"
            if "!LINE:~0,1!"=="[" set "IN_SECTION=0"
            if "!LINE!"=="[CookSettings]" set "IN_SECTION=1"
            if "!IN_SECTION!"=="0" echo !LINE!
        )
    )
    move /Y "!DEFAULTEDITOR!.tmp" "!DEFAULTEDITOR!" >nul
)

(
    echo.
    echo [CookSettings]
    echo CookContentMissingSeverity=Warning
) >> "!DEFAULTEDITOR!"

echo.
echo Setup complete!
echo Unpacked project is at: !SOURCE_DIR!\HalfswordUE5
echo.
explorer "!SOURCE_DIR!\HalfswordUE5"
pause
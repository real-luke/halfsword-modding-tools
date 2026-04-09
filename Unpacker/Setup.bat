@echo off
setlocal enabledelayedexpansion

set "TOOLS_DIR=%LOCALAPPDATA%\HalfSwordModTools"
set "CFG=!TOOLS_DIR!\paths.ini"
set "AES_KEY=0xBCBF7B45A4A8150D06F7B955BC25EF5CE603470F508302CAD0EB48FEA2D91517"
set "PAK=pakchunk0-Windows.pak"

REM === Load saved paths ===
if exist "%CFG%" (
    for /f "tokens=1* delims==" %%A in ("%CFG%") do set "%%A=%%B"
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
    echo [^!] Invalid Half Sword folder - Paks directory not found.
    pause & exit /b
)

REM === Ask where to put the unpacked source ===
if not defined SOURCE_DIR set "SOURCE_DIR=C:\HalfSwordSource"
set /p "SOURCE_DIR=Where to put the unpacked source (leave blank for !SOURCE_DIR!): "
if "!SOURCE_DIR!"=="" set "SOURCE_DIR=C:\HalfSwordSource"
set "SOURCE_DIR=!SOURCE_DIR:"=!"

REM Normalize trailing slash and validate user-provided output path
set "SOURCE_DIR_NORM=!SOURCE_DIR!"
if "!SOURCE_DIR_NORM:~-1!"=="\" set "SOURCE_DIR_NORM=!SOURCE_DIR_NORM:~0,-1!"
if "!SOURCE_DIR_NORM!"=="" set "SOURCE_DIR_NORM=C:\HalfSwordSource"
set "SOURCE_DIR=!SOURCE_DIR_NORM!"

if not "!SOURCE_DIR:~1,2!"==":\" (
    echo [^!] SOURCE_DIR must be an absolute local path like C:\HalfSwordSource
    pause & exit /b
)

echo(!SOURCE_DIR!| findstr /R "[<>|?*]" >nul
if not errorlevel 1 (
    echo [^!] SOURCE_DIR contains invalid characters. Do not use ^< ^> ^| ? *
    pause & exit /b
)

echo(!SOURCE_DIR:~2!| findstr ":" >nul
if not errorlevel 1 (
    echo [^!] SOURCE_DIR is invalid. Use a normal path like C:\HalfSwordSource
    pause & exit /b
)

if "!SOURCE_DIR:~3!"=="" (
    echo [^!] SOURCE_DIR cannot be a drive root. Pick a folder like C:\HalfSwordSource
    pause & exit /b
)

set "GAME_DIR_NORM=!GAME_DIR!"
if "!GAME_DIR_NORM:~-1!"=="\" set "GAME_DIR_NORM=!GAME_DIR_NORM:~0,-1!"
if /I "!SOURCE_DIR!"=="!GAME_DIR_NORM!" (
    echo [^!] SOURCE_DIR cannot be the game install folder.
    pause & exit /b
)

if not exist "!SOURCE_DIR!" (
    mkdir "!SOURCE_DIR!" >nul 2>&1
    if errorlevel 1 (
        echo [^!] SOURCE_DIR could not be created: !SOURCE_DIR!
        echo [^!] Choose a writable folder path and run Setup.bat again.
        pause & exit /b
    )
    rmdir /S /Q "!SOURCE_DIR!" >nul 2>&1
)

if exist "!SOURCE_DIR!" (
    echo.
    echo [^!] !SOURCE_DIR! already exists.
    echo     This could be a partial or outdated unpack. It will be deleted and replaced.
    choice /C YN /M "Delete it and do a fresh unpack"
    if errorlevel 2 (
        echo Setup cancelled.
        pause & exit /b
    )
)

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

if exist "%~dp0..\Binaries\repak.exe" (
    copy /Y "%~dp0..\Binaries\repak.exe" "!REPAK_EXE!" >nul
) else if exist "%~dp0repak.exe" (
    copy /Y "%~dp0repak.exe" "!REPAK_EXE!" >nul
)

if exist "%~dp0..\Binaries\oo2core_9_win64.dll" (
    copy /Y "%~dp0..\Binaries\oo2core_9_win64.dll" "!OODLE_DLL!" >nul
) else if exist "%~dp0oo2core_9_win64.dll" (
    copy /Y "%~dp0oo2core_9_win64.dll" "!OODLE_DLL!" >nul
)

if exist "!REPAK_EXE!" (
    set "REPAK_CMD=!REPAK_EXE!"
    set "REPAK_MODE=BUNDLED"
) else (
    where repak >nul 2>&1
    if errorlevel 1 (
        echo [^!] repak.exe not found in !TOOLS_DIR! and not found in PATH.
        echo [^!] Put repak.exe ^(and oo2core_9_win64.dll^) in the Binaries folder next to this script.
        pause & exit /b
    )
)

if /I "!REPAK_MODE!"=="BUNDLED" (
    echo Using bundled repak.
    if not exist "!OODLE_DLL!" (
        echo [^!] Warning: oo2core_9_win64.dll not found - unpack may fail on Oodle-compressed assets.
    )
) else (
    echo Using repak from PATH ^(no bundled repak found^).
)

REM === Clean up any leftover repak output folder in Paks ===
set "PAK_PATH=!PAKS_DIR!\%PAK%"
set "REPAK_OUT=!PAKS_DIR!\pakchunk0-Windows"

if not exist "!PAK_PATH!" (
    echo [^!] Could not find !PAK_PATH!
    pause & exit /b
)

if exist "!REPAK_OUT!" (
    echo Removing leftover unpack folder from Paks...
    rmdir /S /Q "!REPAK_OUT!"
    if exist "!REPAK_OUT!" (
        echo [^!] Could not delete: !REPAK_OUT!
        echo [^!] Close any Explorer or editor windows that may have it open, then run Setup.bat again.
        pause & exit /b
    )
)

REM === Unpack pak ===
echo Unpacking %PAK%... ^(this will take a while^)
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
    echo [^!] repak exited with code !REPAK_EXIT! - unpack did not complete.
    if exist "!REPAK_OUT!" (
        echo     Cleaning up partial output...
        rmdir /S /Q "!REPAK_OUT!" >nul 2>&1
    )
    echo [^!] If you saw "Oodle initialization failed", make sure oo2core_9_win64.dll is in the Binaries folder.
    pause & exit /b
)

if not exist "!REPAK_OUT!" (
    echo [^!] Unpack appeared to succeed but output folder was not found: !REPAK_OUT!
    pause & exit /b
)

REM === Move to SOURCE_DIR ===
if exist "!SOURCE_DIR!" (
    echo Removing existing source directory...
    rmdir /S /Q "!SOURCE_DIR!"
    if exist "!SOURCE_DIR!" (
        echo [^!] Could not delete: !SOURCE_DIR!
        echo [^!] Close any Explorer or editor windows that may have it open, then run Setup.bat again.
        rmdir /S /Q "!REPAK_OUT!" >nul 2>&1
        pause & exit /b
    )
)

echo Moving unpacked files to !SOURCE_DIR!...
move "!REPAK_OUT!" "!SOURCE_DIR!" >nul
if not exist "!SOURCE_DIR!" (
    echo [^!] Move failed.
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
    echo [^!] HalfswordUE5.uproject not found next to this script - skipping.
)

REM === Copy Binaries ===
if exist "%~dp0Binaries" (
    echo Copying Binaries...
    xcopy /E /I /Y "%~dp0Binaries" "!UNPACK_DIR!\HalfswordUE5\Binaries" >nul
) else (
    echo [^!] Binaries folder not found next to this script - skipping.
)

REM === Copy Source folder (dummied module) ===
if exist "%~dp0Source" (
    echo Copying Source folder...
    xcopy /E /I /Y "%~dp0Source" "!UNPACK_DIR!\HalfswordUE5\Source" >nul
) else (
    echo [^!] Source folder not found next to this script - skipping.
)

REM === Copy Suzie plugin ===
if exist "%~dp0Plugins\Suzie" (
    echo Copying Suzie plugin...
    xcopy /E /I /Y "%~dp0Plugins\Suzie" "!UNPACK_DIR!\HalfswordUE5\Plugins\Suzie" >nul
) else (
    echo [^!] Plugins\Suzie not found next to this script - skipping.
)

REM === Copy jmap ===
if exist "%~dp0Content\DynamicClasses\output.jmap" (
    echo Copying output.jmap...
    if not exist "!UNPACK_DIR!\HalfswordUE5\Content\DynamicClasses\" mkdir "!UNPACK_DIR!\HalfswordUE5\Content\DynamicClasses\"
    copy /Y "%~dp0Content\DynamicClasses\output.jmap" "!UNPACK_DIR!\HalfswordUE5\Content\DynamicClasses\output.jmap" >nul
) else (
    echo [^!] Content\DynamicClasses\output.jmap not found next to this script - skipping.
)

REM === Copy cook and package scripts to project ===
for %%F in (Cook.bat YourPakName.bat) do (
    if exist "%~dp0..\Scripts\%%F" (
        echo Copying %%F to project...
        copy /Y "%~dp0..\Scripts\%%F" "!UNPACK_DIR!\HalfswordUE5\%%F" >nul
    ) else if exist "%~dp0..\Batch\%%F" (
        echo Copying %%F to project...
        copy /Y "%~dp0..\Batch\%%F" "!UNPACK_DIR!\HalfswordUE5\%%F" >nul
    )
)

REM === Delete crash-causing MetaHuman hair files ===
set "HAIR_DIR=!UNPACK_DIR!\HalfswordUE5\Content\MetaHumans\Taro\MaleHair\Hair"
if exist "!HAIR_DIR!" (
    echo Removing crash-causing hair files...
    del /Q "!HAIR_DIR!\Hair_M_SideSweptFringe.*" >nul 2>&1
)

REM === Write DefaultGame.ini ===
set "CONTENT_DIR=!UNPACK_DIR!\HalfswordUE5\Content"
set "CONFIG_DIR=!UNPACK_DIR!\HalfswordUE5\Config"
set "DEFAULTGAME=!CONFIG_DIR!\DefaultGame.ini"

if not exist "!CONFIG_DIR!" mkdir "!CONFIG_DIR!"

echo Writing DefaultGame.ini...

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

(
    echo.
    echo [/Script/UnrealEd.ProjectPackagingSettings]
    echo bSkipEditorContent=True
    for /d %%D in ("!CONTENT_DIR!\*") do echo +DirectoriesToNeverCook=(Path="/Game/%%~nxD"^)
) >> "!DEFAULTGAME!"

REM === Write DefaultEngine.ini ===
set "DEFAULTENGINE=!CONFIG_DIR!\DefaultEngine.ini"

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

set "DEFAULTEDITOR=!CONFIG_DIR!\DefaultEditor.ini"

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
@echo off
setlocal enabledelayedexpansion

set "TOOLS_DIR=%LOCALAPPDATA%\HalfSwordModTools"
set "CFG=!TOOLS_DIR!\paths.ini"

if exist "%CFG%" (
    for /f "tokens=1,2 delims==" %%A in ("%CFG%") do set "%%A=%%B"
)

for %%F in (*.uproject) do set "UPROJECT=%%~dpnxF"
if not defined UPROJECT echo [!] No .uproject found here. & pause & exit /b

if not exist "!ENGINE_DIR!\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" (
    for %%K in (
        "HKLM\SOFTWARE\EpicGames\Unreal Engine\5.4"
        "HKCU\SOFTWARE\EpicGames\Unreal Engine\5.4"
    ) do (
        for /f "tokens=2*" %%A in ('reg query "%%~K" /v "InstalledDirectory" 2^>nul') do (
            if exist "%%B\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" (
                set "ENGINE_DIR=%%B"
                goto :found
            )
        )
    )
)

:found
if not exist "!ENGINE_DIR!\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" (
    set /p ENGINE_DIR="Paste your UE 5.4 folder (e.g., C:\Program Files\Epic Games\UE_5.4): "
    set "ENGINE_DIR=!ENGINE_DIR:"=!"
)

if not exist "!ENGINE_DIR!\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" echo [!] Invalid Engine path. & pause & exit /b

if not exist "!TOOLS_DIR!\" mkdir "!TOOLS_DIR!\"
(
    echo ENGINE_DIR=!ENGINE_DIR!
    if defined GAME_DIR echo GAME_DIR=!GAME_DIR!
    if defined SOURCE_DIR echo SOURCE_DIR=!SOURCE_DIR!
) > "%CFG%"

echo Fixing redirectors...
"!ENGINE_DIR!\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "!UPROJECT!" ^
  -run=ResavePackages -fixupredirects -projectonly -unattended -stdout -NoLogTimes

echo.
echo Cooking project...
"!ENGINE_DIR!\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "!UPROJECT!" ^
  -run=cook -targetplatform=Windows -unversioned -projectonly ^
  -CookDir="/Game/Mods"+"/Game/CustomMaps" ^
  -ini:Game:[/Script/UnrealEd.ProjectPackagingSettings]:bShareMaterialShaderCode=False ^
  -ini:Game:[/Script/UnrealEd.ProjectPackagingSettings]:bSharedMaterialNativeLibraries=False ^
  -stdout -NoLogTimes -iterate
echo.

if %errorlevel% neq 0 (
    echo [!] Cook FAILED with exit code %errorlevel%
    echo Please check the output above for details; packaging may still work.
    pause
    exit /b %errorlevel%
) else (
    echo Finished cooking!
    pause
)

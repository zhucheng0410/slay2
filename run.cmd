@echo off
rem ============================================================================
rem CardRelicForge launcher.
rem
rem Pure batch on purpose: Windows ships with ExecutionPolicy=Restricted, which
rem blocks .ps1 files entirely (SecurityError / UnauthorizedAccess). This script
rem never needs PowerShell, so you never have to change your system settings.
rem
rem IMPORTANT: %~dp0 is correct Unicode, but `for /f` (batch file reading) is
rem NOT reliable for UTF-8. This project lives under a non-ASCII path, so we
rem derive every path from %~dp0 and only consult forge-paths.txt as a last
rem resort. Keep any override in forge-paths.txt ASCII-only.
rem ============================================================================
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
set "GODOT="
set "USERDIR="

rem --- 1. auto-detect the engine (relative to %~dp0, always Unicode-safe) -----
call :probe "%HERE%..\Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64.exe"
call :probe "%HERE%..\Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64.exe"
call :probe "%HERE%Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64.exe"
call :probe "%HERE%..\Godot_v4.5.1-stable_mono_win64.exe"

rem --- 2. optional override for a completely different engine location -------
rem     Only consulted when probing failed. Values must be plain ASCII paths.
if not defined GODOT call :read_override

rem --- 3. the *_console.exe is only a ~200 KB stub; prefer the real binary ----
if defined GODOT (
  echo !GODOT! | findstr /i /c:"_console.exe" >nul
  if not errorlevel 1 (
    set "REAL=!GODOT:_console.exe=.exe!"
    if exist "!REAL!" set "GODOT=!REAL!"
  )
)

if not defined GODOT (
  echo.
  echo Could not find the Godot 4.5.1 mono executable.
  echo.
  echo Fix: open forge-paths.txt next to run.cmd and set the full path:
  echo   godot=C:\Godot\Godot_v4.5.1-stable_mono_win64.exe
  echo Use the real Godot 4.5.1 MONO executable, not the regular or console build.
  echo Keep this path ASCII-only, or put the Godot folder beside CardRelicForge.
  echo Then save the file and run run.cmd again.
  echo.
  pause
  endlocal & exit /b 1
)

rem --- 4. userdir: keep the engine's APPDATA writes inside the project -------
if not defined USERDIR set "USERDIR=%HERE%.forge_userdata"
if not exist "%USERDIR%" mkdir "%USERDIR%"
set "APPDATA=%USERDIR%"

echo Launching CardRelicForge...
echo   engine : %GODOT%
echo   userdir: %USERDIR%

rem This is a runtime project (run/main_scene), so a plain launch opens the tool
rem window directly. No --editor-pid, no plugin step.
"%GODOT%" --path "%HERE%."
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%

rem ---------------------------------------------------------------------------
:probe
if not defined GODOT if exist %1 set "GODOT=%~f1"
goto :eof

:read_override
set "PATHS=%HERE%forge-paths.txt"
if not exist "%PATHS%" goto :eof
for /f "usebackq tokens=1,* delims==" %%A in ("%PATHS%") do (
  set "K=%%A"
  set "V=%%B"
  if /i "!K!"=="godot"   if not defined GODOT set "GODOT=!V!"
  if /i "!K!"=="userdir" if not defined USERDIR set "USERDIR=!V!"
)
rem Reject a garbled read instead of failing later with a confusing path.
if defined GODOT if not exist "!GODOT!" set "GODOT="
goto :eof

@echo off
REM ===========================================================================
REM  Hoshi Pre-translate - double-click this. That's it.
REM
REM  Nothing has to be installed first. On the first run this downloads a
REM  private, self-contained copy of Python into %LOCALAPPDATA% and installs
REM  the handful of packages it needs. Your system Python (if any) is never
REM  touched, and nothing is added to PATH.
REM
REM  Everything large lives under %LOCALAPPDATA%\HoshiPretranslate, so this
REM  folder stays small even if you keep it in Dropbox.
REM ===========================================================================
setlocal EnableExtensions
cd /d "%~dp0"

set "APPDIR=%LOCALAPPDATA%\HoshiPretranslate"
set "PYDIR=%APPDIR%\python"
set "PYEXE=%PYDIR%\python.exe"
set "PYWEXE=%PYDIR%\pythonw.exe"
set "STAMP=%PYDIR%\.deps-installed"
set "PYTHONPATH=%~dp0"
set "PYURL=https://github.com/astral-sh/python-build-standalone/releases/download/20260728/cpython-3.12.13+20260728-x86_64-pc-windows-msvc-install_only.tar.gz"

if exist "%PYEXE%" if exist "%STAMP%" goto launch

echo.
echo   Hoshi Pre-translate - first-time setup
echo   =====================================
echo   This downloads a private copy of Python (~45 MB) plus a few packages.
echo   Nothing is installed system-wide. This takes a minute or two.
echo.

if not exist "%APPDIR%" mkdir "%APPDIR%" 2>nul

if exist "%PYEXE%" goto deps

REM ---- download -------------------------------------------------------------
set "PYTGZ=%APPDIR%\python-runtime.tar.gz"
if exist "%PYTGZ%" del /f /q "%PYTGZ%" >nul 2>nul

echo   [1/3] Downloading Python ...
where curl.exe >nul 2>nul
if errorlevel 1 goto dl_powershell

curl.exe -L --fail --retry 3 --retry-delay 2 -o "%PYTGZ%" "%PYURL%"
if errorlevel 1 goto dl_powershell
goto dl_done

:dl_powershell
echo         (using PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -Uri '%PYURL%' -OutFile '%PYTGZ%' -UseBasicParsing"
if errorlevel 1 goto fail_download

:dl_done
if not exist "%PYTGZ%" goto fail_download

REM ---- extract --------------------------------------------------------------
echo   [2/3] Extracting ...
where tar.exe >nul 2>nul
if errorlevel 1 goto ex_powershell

tar.exe -xf "%PYTGZ%" -C "%APPDIR%"
if errorlevel 1 goto ex_powershell
goto ex_done

:ex_powershell
echo         (using PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; tar -xf '%PYTGZ%' -C '%APPDIR%'"
if errorlevel 1 goto fail_extract

:ex_done
del /f /q "%PYTGZ%" >nul 2>nul
if not exist "%PYEXE%" goto fail_extract

REM ---- dependencies ---------------------------------------------------------
:deps
echo   [3/3] Installing packages ...
"%PYEXE%" -m pip install --disable-pip-version-check --no-warn-script-location -r "%~dp0requirements.txt"
if errorlevel 1 goto fail_deps

REM Fail loudly here rather than launching a GUI that silently never appears.
"%PYEXE%" -c "import tkinter, requests, remotezip" 2>nul
if errorlevel 1 goto fail_deps

echo done > "%STAMP%"
echo.
echo   Setup complete.
echo.

REM ---- launch ---------------------------------------------------------------
:launch
REM Import the app first with the console python: pythonw.exe discards stderr,
REM so without this a startup error would show as "nothing happens at all".
"%PYEXE%" -c "import hoshi_pretranslate.gui" 2>"%TEMP%\hoshi-pretranslate-startup.log"
if errorlevel 1 goto fail_start

start "" "%PYWEXE%" -m hoshi_pretranslate
exit /b 0

REM ---- failures -------------------------------------------------------------
:fail_download
echo.
echo   COULD NOT DOWNLOAD PYTHON.
echo   Check your internet connection (a VPN or company proxy can block GitHub)
echo   and run this again. Nothing was installed.
echo.
pause
exit /b 1

:fail_extract
echo.
echo   COULD NOT EXTRACT PYTHON.
echo   Delete this folder and run this file again:
echo     %PYDIR%
echo.
pause
exit /b 1

:fail_deps
echo.
echo   COULD NOT INSTALL THE REQUIRED PACKAGES.
echo   This is almost always a network/proxy problem. Try again; if it keeps
echo   failing, delete this folder and start over:
echo     %PYDIR%
echo.
pause
exit /b 1

:fail_start
echo.
echo   THE APP FAILED TO START. Details:
echo.
type "%TEMP%\hoshi-pretranslate-startup.log"
echo.
pause
exit /b 1

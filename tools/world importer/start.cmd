@echo off
setlocal
cd /d "%~dp0"

python --version >nul 2>nul
if not errorlevel 1 goto run_python

py -3 --version >nul 2>nul
if not errorlevel 1 goto run_py

echo Python 3 was not found. Install Python 3.11 or newer.
exit /b 1

:run_python
set PYTHONUTF8=1
python world_importer_ui.py %*
exit /b %errorlevel%

:run_py
set PYTHONUTF8=1
py -3 world_importer_ui.py %*
exit /b %errorlevel%

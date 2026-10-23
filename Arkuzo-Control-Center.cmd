@echo off
rem Opens the Arkuzo Control Center for this checkout. It supervises the saver
rem (src\saver) against data\ and keeps running in the background if you close the window.
setlocal
set "PYW=pythonw.exe"
where pythonw.exe >nul 2>nul || set "PYW=python.exe"
start "" "%PYW%" "%~dp0src\saver\Arkuzo-Control-Center.py" --data "%~dp0data"

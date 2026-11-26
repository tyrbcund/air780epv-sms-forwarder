@echo off
setlocal
if "%~1"=="" goto usage
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0soc_inspect.ps1" -Soc "%~1"
echo.
pause
exit /b

:usage
echo.
echo   Drag and drop a .soc firmware file onto this .bat
echo.
pause
exit /b
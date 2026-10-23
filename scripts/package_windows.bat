@echo off
rem One-click Windows release: build, add VC++ runtime DLLs, zip.
rem Double-click this file, or run: scripts\package_windows.bat
setlocal
chcp 65001 >nul
title Shengwuji Desktop - package

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0package_windows.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo [FAILED] exit code %EXIT_CODE% - see the error above.
) else (
    echo [OK] done.
)
echo.
pause
exit /b %EXIT_CODE%

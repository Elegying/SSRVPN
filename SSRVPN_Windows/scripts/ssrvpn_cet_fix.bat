@echo off
:: SSRVPN CET Compatibility Fix Launcher
:: Run this as Administrator (right-click → Run as Administrator)
:: if SSRVPN crashes on startup on Windows 11 25H2+.

setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ssrvpn_cet_fix.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Press any key to exit...
    pause >nul
)

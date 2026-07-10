@echo off
:: Cleanup only: restores Windows mitigation defaults left by older SSRVPN.
:: Right-click this file and choose "Run as administrator" once.

setlocal
set "SCRIPT_DIR=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" ^
  -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
  -File "%SCRIPT_DIR%remove_legacy_cet_exemption.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if %EXIT_CODE% NEQ 0 (
  echo.
  echo Cleanup failed. Review the error above.
  pause
)
exit /b %EXIT_CODE%

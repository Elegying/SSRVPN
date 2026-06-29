@echo off
cd /d "%~dp0"
start "" "%~dp0ssrvpn_windows.exe" --safe-mode --verbose

SSRVPN Safe Mode / Startup Diagnostics

If SSRVPN opens with no window or crashes immediately, try safe mode:

1. Double-click ssrvpn_safe_mode.bat
2. Or run this command from the release directory:
   ssrvpn_windows.exe --safe-mode --verbose

Safe mode skips:
- system tray initialization
- saved window position restoration
- Mihomo core automatic initialization

Startup logs:
%LOCALAPPDATA%\SSRVPN\logs\startup.log

Native crash dumps:
%LOCALAPPDATA%\SSRVPN\crashes\

When reporting a startup crash, please send:
- startup.log
- all files in the crashes directory
- the exact command line used to start SSRVPN

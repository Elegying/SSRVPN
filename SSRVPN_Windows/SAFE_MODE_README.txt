SSRVPN Safe Mode / Startup Diagnostics

If SSRVPN opens with no window or crashes immediately, try safe mode:

1. Double-click ssrvpn_safe_mode.bat
2. Or run this command from the release directory:
   ssrvpn_windows.exe --safe-mode --verbose

Always start SSRVPN through the root ssrvpn_windows.exe. The
bin\ssrvpn_windows_app.exe file is an internal application process used by the
launcher.

Safe mode skips:
- system tray initialization
- saved window position restoration
- Mihomo core automatic initialization

Startup logs:
%LOCALAPPDATA%\SSRVPN\logs\startup.log

Native crash dumps:
%LOCALAPPDATA%\SSRVPN\crashes\

When reporting a startup crash, please send text logs first:
- startup.log
- ssrvpn_diag.log, if you ran SSRVPN_Diag.bat
- the exact command line used to start SSRVPN

Do not post .dmp files publicly. Crash dumps may include local paths,
subscription URLs, or other private runtime data. Share them only through a
private support channel if a developer explicitly asks for them.

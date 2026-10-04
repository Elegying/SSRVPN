#ifndef RUNNER_TRAY_SHELL_NOTIFICATIONS_H_
#define RUNNER_TRAY_SHELL_NOTIFICATIONS_H_

#include <windows.h>

// Explorer normally runs at medium integrity while SSRVPN is elevated.
// Allow only the payload-free taskbar recreation notification on this window;
// the system_tray plugin handles it by re-adding its existing icon.
inline bool EnableTaskbarRecreationNotifications(HWND window) {
  const UINT message = ::RegisterWindowMessageW(L"TaskbarCreated");
  return message != 0 &&
         ::ChangeWindowMessageFilterEx(window, message, MSGFLT_ALLOW, nullptr);
}

#endif  // RUNNER_TRAY_SHELL_NOTIFICATIONS_H_

part of desktop_home_screen;

@visibleForTesting
bool desktopStatusNotificationChangesState({
  required bool wasConnected,
  required bool isRunning,
  required String? previousWarning,
  required String? nextWarning,
  required bool cancelledWhileConnecting,
}) =>
    wasConnected != isRunning ||
    previousWarning != nextWarning ||
    cancelledWhileConnecting;

@visibleForTesting
String? desktopConnectionCancellationNotice({
  required bool stopSucceeded,
  required bool isRunning,
}) =>
    stopSucceeded && !isRunning ? '连接已取消' : null;

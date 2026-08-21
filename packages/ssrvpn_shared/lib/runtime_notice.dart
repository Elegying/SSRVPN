import 'dart:async';

enum RuntimeNoticeLevel { success, progress, warning, error }

class RuntimeNotice {
  const RuntimeNotice(this.message, {required this.level});

  const RuntimeNotice.success(String message)
      : this(message, level: RuntimeNoticeLevel.success);

  const RuntimeNotice.progress(String message)
      : this(message, level: RuntimeNoticeLevel.progress);

  const RuntimeNotice.warning(String message)
      : this(message, level: RuntimeNoticeLevel.warning);

  const RuntimeNotice.error(String message)
      : this(message, level: RuntimeNoticeLevel.error);

  final String message;
  final RuntimeNoticeLevel level;
}

const coreAutoRecoveredRuntimeNotice = RuntimeNotice.success('核心已自动恢复');
const runtimeNoticeSuccessDuration = Duration(seconds: 3);
const windowsTunElevationHandoffRuntimeNotice = RuntimeNotice.progress(
  '管理员授权已通过。SSRVPN 将暂时关闭当前窗口，并自动以管理员模式重新打开、继续连接 TUN；'
  '请耐心等待，不要重复启动软件。',
);
const windowsTunElevationHandoffNoticeDuration = Duration(seconds: 3);

Timer? scheduleSuccessfulRuntimeNoticeClear({
  required RuntimeNotice notice,
  required RuntimeNotice? Function() currentNotice,
  required void Function() clear,
  Duration delay = runtimeNoticeSuccessDuration,
}) {
  if (notice.level != RuntimeNoticeLevel.success) return null;

  return Timer(delay, () {
    if (identical(currentNotice(), notice)) clear();
  });
}

bool shouldClearRuntimeNoticeOnRunningEdge({
  required bool wasRunning,
  required bool isRunning,
  required RuntimeNotice? notice,
}) =>
    notice != null && !wasRunning && isRunning;

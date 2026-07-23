import 'dart:async';

const coreAutoRecoveredRuntimeNotice = '核心已自动恢复';
const runtimeNoticeSuccessDuration = Duration(seconds: 3);
const windowsTunElevationHandoffRuntimeNotice =
    '管理员授权已通过。SSRVPN 将暂时关闭当前窗口，并自动以管理员模式重新打开、继续连接 TUN；'
    '请耐心等待，不要重复启动软件。';
const windowsTunElevationHandoffNoticeDuration = Duration(seconds: 3);

bool isSuccessfulRuntimeNotice(String? message) =>
    message == coreAutoRecoveredRuntimeNotice;

bool isInProgressRuntimeNotice(String? message) =>
    message == windowsTunElevationHandoffRuntimeNotice;

Timer? scheduleSuccessfulRuntimeNoticeClear({
  required String message,
  required String? Function() currentMessage,
  required void Function() clear,
  Duration delay = runtimeNoticeSuccessDuration,
}) {
  if (!isSuccessfulRuntimeNotice(message)) return null;

  return Timer(delay, () {
    if (currentMessage() == message) clear();
  });
}

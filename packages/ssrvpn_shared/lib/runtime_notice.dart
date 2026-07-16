import 'dart:async';

const coreAutoRecoveredRuntimeNotice = '核心已自动恢复';
const runtimeNoticeSuccessDuration = Duration(seconds: 3);

bool isSuccessfulRuntimeNotice(String? message) =>
    message == coreAutoRecoveredRuntimeNotice;

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

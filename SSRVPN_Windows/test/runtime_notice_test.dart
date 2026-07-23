import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';

void main() {
  test('only the exact recovery notice is successful', () {
    expect(isSuccessfulRuntimeNotice(coreAutoRecoveredRuntimeNotice), isTrue);
    expect(isSuccessfulRuntimeNotice(' 核心已自动恢复'), isFalse);
    expect(isSuccessfulRuntimeNotice('核心异常退出，正在自动恢复'), isFalse);
    expect(isSuccessfulRuntimeNotice(null), isFalse);
  });

  test('only the exact TUN elevation handoff notice is in progress', () {
    expect(
      isInProgressRuntimeNotice(windowsTunElevationHandoffRuntimeNotice),
      isTrue,
    );
    expect(
      isInProgressRuntimeNotice(
        '$windowsTunElevationHandoffRuntimeNotice ',
      ),
      isFalse,
    );
    expect(isInProgressRuntimeNotice(coreAutoRecoveredRuntimeNotice), isFalse);
    expect(isInProgressRuntimeNotice(null), isFalse);
  });

  testWidgets('successful notice clears after its display duration', (
    tester,
  ) async {
    String? currentMessage = coreAutoRecoveredRuntimeNotice;
    var clearCount = 0;

    final timer = scheduleSuccessfulRuntimeNoticeClear(
      message: currentMessage,
      currentMessage: () => currentMessage,
      clear: () {
        clearCount++;
        currentMessage = null;
      },
    );

    expect(timer, isNotNull);
    await tester.pump(
      runtimeNoticeSuccessDuration - const Duration(milliseconds: 1),
    );
    expect(clearCount, 0);

    await tester.pump(const Duration(milliseconds: 1));
    expect(clearCount, 1);
    expect(currentMessage, isNull);
  });

  testWidgets('old success timer does not clear a newer notice',
      (tester) async {
    String? currentMessage = coreAutoRecoveredRuntimeNotice;
    var clearCount = 0;

    scheduleSuccessfulRuntimeNoticeClear(
      message: currentMessage,
      currentMessage: () => currentMessage,
      clear: () => clearCount++,
    );
    currentMessage = '连接已断开：核心自动恢复失败';

    await tester.pump(runtimeNoticeSuccessDuration);
    expect(clearCount, 0);
    expect(currentMessage, '连接已断开：核心自动恢复失败');
  });

  test('error notice is not scheduled for automatic clearing', () {
    final timer = scheduleSuccessfulRuntimeNoticeClear(
      message: '连接未完成',
      currentMessage: () => '连接未完成',
      clear: () {},
    );

    expect(timer, isNull);
  });
}

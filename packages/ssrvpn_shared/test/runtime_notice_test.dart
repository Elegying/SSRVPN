import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';

void main() {
  test('notice level is independent from its user-facing text', () {
    expect(
      const RuntimeNotice.success('连接未完成').level,
      RuntimeNoticeLevel.success,
    );
    expect(
      const RuntimeNotice.error('核心已自动恢复').level,
      RuntimeNoticeLevel.error,
    );
    expect(
      windowsTunElevationHandoffRuntimeNotice.level,
      RuntimeNoticeLevel.progress,
    );
  });

  testWidgets('a dynamic success notice clears after its display duration', (
    tester,
  ) async {
    final notice = RuntimeNotice.success('端口已自动调整');
    RuntimeNotice? currentNotice = notice;
    var clearCount = 0;

    final timer = scheduleSuccessfulRuntimeNoticeClear(
      notice: notice,
      currentNotice: () => currentNotice,
      clear: () {
        clearCount++;
        currentNotice = null;
      },
    );

    expect(timer, isNotNull);
    await tester.pump(runtimeNoticeSuccessDuration);
    expect(clearCount, 1);
    expect(currentNotice, isNull);
  });

  testWidgets('an old success timer never clears a newer notice', (
    tester,
  ) async {
    final oldNotice = RuntimeNotice.success('端口已自动调整');
    RuntimeNotice? currentNotice = oldNotice;
    var clearCount = 0;

    scheduleSuccessfulRuntimeNoticeClear(
      notice: oldNotice,
      currentNotice: () => currentNotice,
      clear: () => clearCount++,
    );
    currentNotice = const RuntimeNotice.warning('外部网络检查暂时不可用');

    await tester.pump(runtimeNoticeSuccessDuration);
    expect(clearCount, 0);
    expect(currentNotice.level, RuntimeNoticeLevel.warning);
  });

  test('only success notices are scheduled for automatic clearing', () {
    const notice = RuntimeNotice.error('连接未完成');
    final timer = scheduleSuccessfulRuntimeNoticeClear(
      notice: notice,
      currentNotice: () => notice,
      clear: () {},
    );

    expect(timer, isNull);
  });

  test('a successful disconnected-to-running edge clears an old failure', () {
    expect(
      shouldClearRuntimeNoticeOnRunningEdge(
        wasRunning: false,
        isRunning: true,
        notice: const RuntimeNotice.error('上一次连接失败'),
      ),
      isTrue,
    );
  });

  test('an already-running refresh keeps a newer cleanup failure visible', () {
    expect(
      shouldClearRuntimeNoticeOnRunningEdge(
        wasRunning: true,
        isRunning: true,
        notice: const RuntimeNotice.error('系统代理清理状态无法确认'),
      ),
      isFalse,
    );
  });
}

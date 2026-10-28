import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/utils/connection_phase_trace.dart';

void main() {
  test('completed timing freezes and keeps bounded safe history', () {
    var elapsed = const Duration(milliseconds: 123);
    final trace =
        ConnectionPhaseTrace(attempt: 2, emit: (_) {}, clock: () => elapsed);
    for (var i = 0; i < 100; i++) {
      trace.progress(i.isEven ? '正在检查上次运行资源…' : '正在设置系统代理…');
    }
    trace.finish(ConnectionTimingOutcome.localReady);
    final summary = trace.summary;
    elapsed = const Duration(days: 1);
    expect(trace.summary, summary);
    expect(summary, contains('累计 123ms'));
    expect(summary, contains('不能视为纯网卡创建耗时'));
    expect('ms'.allMatches(summary).length, 33);
  });

  test('separates authorization handoff from local readiness monotonically',
      () {
    var elapsed = Duration.zero;
    final logs = <String>[];
    final trace = ConnectionPhaseTrace(
      attempt: 7,
      emit: logs.add,
      clock: () => elapsed,
    );
    elapsed = const Duration(milliseconds: 10);
    trace.progress('正在请求系统授权，请留意授权弹窗…');
    elapsed = const Duration(milliseconds: 6010);
    trace.progress('正在启用 VPN，等待分流规则就绪…');
    elapsed = const Duration(milliseconds: 6060);
    trace.finish(ConnectionTimingOutcome.localReady);
    expect(logs, hasLength(3));
    expect(logs[1], contains('系统授权与提权交接；耗时 6000ms'));
    expect(logs.last, contains('等待本地服务和规则就绪；耗时 50ms'));
    expect(logs.last, contains('累计 6060ms；attempt=7 outcome=localReady'));
  });

  test('unknown text and duplicate progress cannot leak or inflate records',
      () {
    final logs = <String>[];
    final trace = ConnectionPhaseTrace(attempt: 1, emit: logs.add);
    trace.progress('hysteria2://secret@private.example/path');
    trace.progress('正在准备节点和分流规则…');
    trace.progress('正在准备节点和分流规则…');
    trace.finish(ConnectionTimingOutcome.notCompleted);
    trace.finish(ConnectionTimingOutcome.localReady);
    trace.progress('正在设置系统代理…');
    expect(logs, hasLength(2));
    expect(logs.join(), isNot(contains('secret')));
    expect(logs.join(), isNot(contains('private.example')));
    expect(logs.last, contains('outcome=notCompleted'));
    expect(logs.join(), isNot(contains('outcome=localReady')));
  });

  test('a failing diagnostic sink cannot throw into connection work', () {
    final trace = ConnectionPhaseTrace(
      attempt: 1,
      emit: (_) => throw StateError('disk or listener unavailable'),
    );
    expect(() => trace.progress('正在准备节点和分流规则…'), returnsNormally);
    expect(
        () => trace.finish(ConnectionTimingOutcome.disposed), returnsNormally);
  });

  test('clock rollback cannot produce negative elapsed or stage durations', () {
    var elapsed = const Duration(milliseconds: 10);
    final logs = <String>[];
    final trace = ConnectionPhaseTrace(
      attempt: 1,
      emit: logs.add,
      clock: () => elapsed,
    );
    trace.progress('正在准备节点和分流规则…');
    elapsed = const Duration(milliseconds: -100);
    trace.finish(ConnectionTimingOutcome.notCompleted);
    expect(logs.last, contains('耗时 0ms；累计 10ms'));
  });
}

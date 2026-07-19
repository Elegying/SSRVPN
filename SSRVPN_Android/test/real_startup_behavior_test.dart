import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/startup/startup_flags.dart';
import 'package:ssrvpn_android/startup/startup_logger.dart';
import 'package:ssrvpn_android/startup/startup_orchestrator.dart';
import 'package:ssrvpn_android/startup/startup_status.dart';

void main() {
  group('Android startup behavior', () {
    test('intent extras only enable explicitly true startup flags', () {
      final defaults = StartupFlags.fromMap(null);
      expect(defaults.verbose, isFalse);
      expect(defaults.resetWindow, isFalse);
      expect(defaults.skipUpdateCheck, isFalse);

      final flags = StartupFlags.fromMap({
        'verbose': true,
        'resetData': true,
        'skipUpdateCheck': true,
      });
      expect(flags.verbose, isTrue);
      expect(flags.resetWindow, isTrue);
      expect(flags.skipUpdateCheck, isTrue);

      final legacyReset = StartupFlags.fromMap({
        'verbose': 'true',
        'resetWindow': true,
        'skipUpdateCheck': 1,
      });
      expect(legacyReset.verbose, isFalse);
      expect(legacyReset.resetWindow, isTrue);
      expect(legacyReset.skipUpdateCheck, isFalse);
      expect(StartupFlags.defaults().resetWindow, isFalse);
    });

    test('status records progress, failure details, and immutable history', () {
      final status = StartupStatus();
      expect(status.totalDuration, isNull);
      expect(status.toString(), contains('状态: 进行中'));
      expect(status.toString(), contains('总耗时: N/Ams'));

      status.start();
      status.recordStep('配置', '读取成功');
      status.recordStep('核心', '校验失败', failed: true);

      expect(status.error, '核心: 校验失败');
      expect(status.steps, hasLength(2));
      expect(status.steps.first.failed, isFalse);
      expect(status.steps.last.failed, isTrue);
      expect(status.steps.first.timestamp, isA<DateTime>());
      expect(
          () => status.steps.add(status.steps.first), throwsUnsupportedError);

      status.complete();
      expect(status.isComplete, isTrue);
      expect(status.totalDuration, isNotNull);
      expect(status.toString(), contains('状态: 失败'));
      expect(status.toString(), contains('❌'));
      expect(status.toString(), contains('核心: 校验失败'));
    });

    test('explicit startup failure is complete and user-diagnosable', () {
      final status = StartupStatus()..start();
      status.fail('核心资源不可用');

      expect(status.isComplete, isTrue);
      expect(status.error, '核心资源不可用');
      expect(status.toString(), contains('错误: 核心资源不可用'));
    });

    test('orchestrator completes when update checks are intentionally skipped',
        () async {
      final orchestrator = StartupOrchestrator(
        flags: const StartupFlags(skipUpdateCheck: true),
      );

      await orchestrator.start();

      expect(orchestrator.status.isComplete, isTrue);
      expect(orchestrator.status.error, isNull);
      expect(orchestrator.status.steps, isEmpty);
      expect(orchestrator.status.toString(), contains('状态: 完成'));
    });

    test('startup logs redact credentials and retain only the newest entries',
        () {
      StartupLogger.info('Authorization: Bearer top-secret-token');
      StartupLogger.warn('subscription url token=secret-value');
      StartupLogger.error('bootstrap', 'password=my-password');

      final newLogs = StartupLogger.recentLogs.join('\n');
      expect(newLogs, isNot(contains('top-secret-token')));
      expect(newLogs, isNot(contains('secret-value')));
      expect(newLogs, isNot(contains('my-password')));
      expect(newLogs, contains('***'));

      for (var index = 0; index < 55; index++) {
        StartupLogger.info('bounded-entry-$index');
      }
      expect(StartupLogger.recentLogs, hasLength(50));
      expect(StartupLogger.recentLogs.last, contains('bounded-entry-54'));
      expect(
          StartupLogger.recentLogs.first, isNot(contains('bounded-entry-0')));
    });
  });
}

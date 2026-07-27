import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/macos_start_transaction.dart';

void main() {
  test('proxy failure rolls back before final health check', () async {
    final events = <String>[];
    final result = await MacosStartTransaction().run(
      configureSystemProxy: () async {
        events.add('proxy');
        return false;
      },
      confirmHealthy: () async {
        events.add('health');
        return true;
      },
      commit: () async => events.add('commit'),
      rollback: () async => events.add('rollback'),
      onException: (_, __) => events.add('exception'),
    );

    expect(result, isFalse);
    expect(events, ['proxy', 'rollback']);
  });

  test('health loss after proxy configuration rolls back exactly once',
      () async {
    final events = <String>[];
    final result = await MacosStartTransaction().run(
      configureSystemProxy: () async {
        events.add('proxy');
        return true;
      },
      confirmHealthy: () async {
        events.add('health');
        return false;
      },
      commit: () async => events.add('commit'),
      rollback: () async => events.add('rollback'),
      onException: (_, __) => events.add('exception'),
    );

    expect(result, isFalse);
    expect(events, ['proxy', 'health', 'rollback']);
  });

  test('commit exception is attributed and rolled back', () async {
    MacosStartTransactionStage? failedStage;
    var rollbacks = 0;
    final result = await MacosStartTransaction().run(
      configureSystemProxy: () async => true,
      confirmHealthy: () async => true,
      commit: () async => throw StateError('injected'),
      rollback: () async => rollbacks++,
      onException: (stage, _) => failedStage = stage,
    );

    expect(result, isFalse);
    expect(failedStage, MacosStartTransactionStage.commit);
    expect(rollbacks, 1);
  });

  test('rollback failure is attributed without escaping or retrying cleanup',
      () async {
    final failedStages = <MacosStartTransactionStage>[];
    var rollbacks = 0;
    final result = await MacosStartTransaction().run(
      configureSystemProxy: () async => false,
      confirmHealthy: () async => true,
      commit: () async {},
      rollback: () async {
        rollbacks++;
        throw StateError('injected rollback failure');
      },
      onException: (stage, _) => failedStages.add(stage),
    );

    expect(result, isFalse);
    expect(rollbacks, 1);
    expect(failedStages, [MacosStartTransactionStage.rollback]);
  });

  test('exception reporter failure cannot suppress rollback', () async {
    var rollbacks = 0;
    final result = await MacosStartTransaction().run(
      configureSystemProxy: () async =>
          throw StateError('injected proxy failure'),
      confirmHealthy: () async => true,
      commit: () async {},
      rollback: () async => rollbacks++,
      onException: (_, __) => throw StateError('injected reporter failure'),
    );

    expect(result, isFalse);
    expect(rollbacks, 1);
  });
}

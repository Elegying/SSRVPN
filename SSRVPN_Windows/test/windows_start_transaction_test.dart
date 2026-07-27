import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_start_transaction.dart';

void main() {
  test('networking failure rolls back without checking health or commit',
      () async {
    final events = <String>[];

    final result = await WindowsStartTransaction().run(
      configurePlatformNetworking: () async {
        events.add('network');
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
    expect(events, ['network', 'rollback']);
  });

  test('final health loss rolls back configured networking exactly once',
      () async {
    final events = <String>[];

    final result = await WindowsStartTransaction().run(
      configurePlatformNetworking: () async {
        events.add('network');
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
    expect(events, ['network', 'health', 'rollback']);
  });

  test('commit exception is attributed and rolled back exactly once', () async {
    final events = <String>[];
    WindowsStartTransactionStage? failedStage;

    final result = await WindowsStartTransaction().run(
      configurePlatformNetworking: () async {
        events.add('network');
        return true;
      },
      confirmHealthy: () async {
        events.add('health');
        return true;
      },
      commit: () async {
        events.add('commit');
        throw StateError('injected commit failure');
      },
      rollback: () async => events.add('rollback'),
      onException: (stage, _) {
        failedStage = stage;
        events.add('exception');
      },
    );

    expect(result, isFalse);
    expect(failedStage, WindowsStartTransactionStage.commit);
    expect(events, ['network', 'health', 'commit', 'exception', 'rollback']);
  });

  test('successful transaction commits without rollback', () async {
    final events = <String>[];

    final result = await WindowsStartTransaction().run(
      configurePlatformNetworking: () async {
        events.add('network');
        return true;
      },
      confirmHealthy: () async {
        events.add('health');
        return true;
      },
      commit: () async => events.add('commit'),
      rollback: () async => events.add('rollback'),
      onException: (_, __) => events.add('exception'),
    );

    expect(result, isTrue);
    expect(events, ['network', 'health', 'commit']);
  });

  test('rollback failure is attributed without escaping or retrying cleanup',
      () async {
    final failedStages = <WindowsStartTransactionStage>[];
    var rollbacks = 0;

    final result = await WindowsStartTransaction().run(
      configurePlatformNetworking: () async => false,
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
    expect(failedStages, [WindowsStartTransactionStage.rollback]);
  });

  test('exception reporter failure cannot suppress rollback', () async {
    var rollbacks = 0;

    final result = await WindowsStartTransaction().run(
      configurePlatformNetworking: () async =>
          throw StateError('injected networking failure'),
      confirmHealthy: () async => true,
      commit: () async {},
      rollback: () async => rollbacks++,
      onException: (_, __) => throw StateError('injected reporter failure'),
    );

    expect(result, isFalse);
    expect(rollbacks, 1);
  });
}

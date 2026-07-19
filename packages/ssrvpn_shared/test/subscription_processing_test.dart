import 'dart:async';

import 'package:ssrvpn_shared/services/subscription_processing.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    SubscriptionProcessing.workerStartDelayForTesting = Duration.zero;
  });

  tearDown(() {
    SubscriptionProcessing.workerStartDelayForTesting = Duration.zero;
  });

  test('small processing stays on the caller isolate with synchronous errors',
      () {
    final yamls = List<String>.filled(1001, '');

    expect(
      () => SubscriptionProcessing.mergeAndParse(
        yamls,
        const [],
        SubscriptionRefreshControl(timeout: const Duration(seconds: 1)),
        proxySourceKey: 'ssrvpn-subscription',
        standaloneGroupName: 'Standalone',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('1000'),
        ),
      ),
    );
    expect(SubscriptionProcessing.activeWorkerCount, 0);
  });

  test('large worker preserves merger FormatException type and message',
      () async {
    final yaml = _largeYaml(10001);

    await expectLater(
      SubscriptionProcessing.mergeAndParse(
        [yaml],
        const ['Primary'],
        SubscriptionRefreshControl(timeout: const Duration(seconds: 30)),
        proxySourceKey: 'ssrvpn-subscription',
        standaloneGroupName: 'Standalone',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('10000'),
        ),
      ),
    );
    expect(SubscriptionProcessing.activeWorkerCount, 0);
  });

  test('cancelling large processing terminates every worker without buildup',
      () async {
    SubscriptionProcessing.workerStartDelayForTesting =
        const Duration(seconds: 5);
    final yaml = _largeYaml(2000);
    expect(yaml.length, greaterThan(SubscriptionProcessing.isolateThreshold));

    for (var attempt = 0; attempt < 3; attempt++) {
      final cancellation = SubscriptionRefreshCancellation();
      final control = SubscriptionRefreshControl(
        timeout: const Duration(seconds: 30),
        cancellation: cancellation,
      );
      final processing = SubscriptionProcessing.mergeAndParse(
        [yaml],
        ['Primary'],
        control,
        proxySourceKey: 'ssrvpn-subscription',
        standaloneGroupName: 'Standalone',
      );

      expect(SubscriptionProcessing.activeWorkerCount, 1);
      expect(
        SubscriptionProcessing.pendingWorkerCount,
        1,
        reason: 'cancel must cover the window before Isolate.spawn resolves',
      );
      cancellation.cancel();

      await expectLater(
        processing,
        throwsA(isA<SubscriptionRefreshCancelled>()),
      );
      await _waitForNoWorkers();
    }

    expect(SubscriptionProcessing.activeWorkerCount, 0);
  });

  test('large processing deadline terminates its worker', () async {
    SubscriptionProcessing.workerStartDelayForTesting =
        const Duration(seconds: 5);
    final yaml = _largeYaml(2000);
    final control = SubscriptionRefreshControl(
      timeout: const Duration(milliseconds: 50),
    );

    final processing = SubscriptionProcessing.mergeAndParse(
      [yaml],
      const ['Primary'],
      control,
      proxySourceKey: 'ssrvpn-subscription',
      standaloneGroupName: 'Standalone',
    );

    expect(SubscriptionProcessing.activeWorkerCount, 1);
    await expectLater(
      processing,
      throwsA(isA<SubscriptionRefreshDeadlineExceeded>()),
    );
    await _waitForNoWorkers();
  });

  test('already stopped large processing does not spawn a worker', () async {
    final cancellation = SubscriptionRefreshCancellation()..cancel();
    final control = SubscriptionRefreshControl(
      timeout: const Duration(seconds: 30),
      cancellation: cancellation,
    );
    late Future<MergedSubscriptionResult> processing;

    expect(
      () => processing = SubscriptionProcessing.mergeAndParse(
        [_largeYaml(2000)],
        const ['Primary'],
        control,
        proxySourceKey: 'ssrvpn-subscription',
        standaloneGroupName: 'Standalone',
      ),
      returnsNormally,
    );
    expect(SubscriptionProcessing.activeWorkerCount, 0);
    await expectLater(
      processing,
      throwsA(isA<SubscriptionRefreshCancelled>()),
    );
  });
}

Future<void> _waitForNoWorkers() async {
  final deadline = DateTime.now().add(const Duration(milliseconds: 500));
  while ((SubscriptionProcessing.activeWorkerCount != 0 ||
          SubscriptionProcessing.pendingWorkerCount != 0) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    SubscriptionProcessing.activeWorkerCount,
    0,
    reason: 'cancelled merge/parse isolate must not outlive the refresh',
  );
  expect(
    SubscriptionProcessing.pendingWorkerCount,
    0,
    reason: 'cancelled merge/parse isolate must not leave a pending spawn',
  );
}

String _largeYaml(int count) {
  final buffer = StringBuffer('proxies:\n');
  for (var index = 0; index < count; index++) {
    buffer
      ..writeln('  - name: Node $index')
      ..writeln('    type: ss')
      ..writeln('    server: node-$index.example.com')
      ..writeln('    port: 443')
      ..writeln('    cipher: aes-128-gcm')
      ..writeln('    password: ${'x' * 128}');
  }
  return buffer.toString();
}

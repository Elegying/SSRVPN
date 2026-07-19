import 'dart:async';

import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:test/test.dart';

void main() {
  test('cancellation aborts the active operation and reports cancellation',
      () async {
    final cancellation = SubscriptionRefreshCancellation();
    final control = SubscriptionRefreshControl(
      timeout: const Duration(seconds: 1),
      cancellation: cancellation,
    );
    final pending = Completer<void>();
    var abortCount = 0;

    final guarded = control.wait(
      pending.future,
      onAbort: () => abortCount++,
    );
    cancellation.cancel();

    await expectLater(
      guarded,
      throwsA(isA<SubscriptionRefreshCancelled>()),
    );
    expect(abortCount, 1);
  });

  test('one absolute deadline covers sequential operations', () async {
    final control = SubscriptionRefreshControl(
      timeout: const Duration(milliseconds: 40),
    );

    await control.wait(Future<void>.delayed(const Duration(milliseconds: 25)));

    await expectLater(
      control.wait(Future<void>.delayed(const Duration(milliseconds: 30))),
      throwsA(isA<SubscriptionRefreshDeadlineExceeded>()),
    );
  });

  test('delay is cancellable', () async {
    final cancellation = SubscriptionRefreshCancellation();
    final control = SubscriptionRefreshControl(
      timeout: const Duration(seconds: 1),
      cancellation: cancellation,
    );

    final delayed = control.delay(const Duration(seconds: 1));
    cancellation.cancel();

    await expectLater(
      delayed,
      throwsA(isA<SubscriptionRefreshCancelled>()),
    );
  });

  test('an already stopped control reports through its returned Future',
      () async {
    final cancellation = SubscriptionRefreshCancellation()..cancel();
    final control = SubscriptionRefreshControl(
      timeout: const Duration(seconds: 1),
      cancellation: cancellation,
    );
    late Future<void> guarded;

    expect(
      () => guarded = control.wait(Future<void>.value()),
      returnsNormally,
    );
    await expectLater(
      guarded,
      throwsA(isA<SubscriptionRefreshCancelled>()),
    );
  });

  test('an exhausted deadline reports through its returned Future', () async {
    final control = SubscriptionRefreshControl(timeout: Duration.zero);
    late Future<void> guarded;

    expect(
      () => guarded = control.wait(Future<void>.value()),
      returnsNormally,
    );
    await expectLater(
      guarded,
      throwsA(isA<SubscriptionRefreshDeadlineExceeded>()),
    );
  });
}

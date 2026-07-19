import 'dart:async';

import 'package:ssrvpn_shared/utils/app_modal_coordinator.dart';
import 'package:test/test.dart';

void main() {
  test('modal presentations are serialized and recover after failure',
      () async {
    final firstMayClose = Completer<void>();
    final events = <String>[];

    final first = AppModalCoordinator.run(() async {
      events.add('first-open');
      await firstMayClose.future;
      events.add('first-close');
    });
    final failed = AppModalCoordinator.run<void>(() async {
      events.add('second-open');
      throw StateError('route failed');
    });
    final third = AppModalCoordinator.run(() async {
      events.add('third-open');
      return 3;
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-open']);
    firstMayClose.complete();
    await first;
    await expectLater(failed, throwsStateError);
    expect(await third, 3);
    expect(events, [
      'first-open',
      'first-close',
      'second-open',
      'third-open',
    ]);
  });
}

import 'dart:async';

import 'package:ssrvpn_shared/utils/connection_transition_queue.dart';
import 'package:test/test.dart';

void main() {
  test('rapid connect disconnect reconnect transitions stay ordered', () async {
    final queue = ConnectionTransitionQueue();
    final firstMayFinish = Completer<void>();
    final events = <String>[];

    final firstConnect = queue.run(() async {
      events.add('connect-1-start');
      await firstMayFinish.future;
      events.add('connect-1-end');
      return true;
    });
    final disconnect = queue.run(() async {
      events.add('disconnect');
    });
    final latestConnect = queue.run(() async {
      events.add('connect-3');
      return true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['connect-1-start']);
    firstMayFinish.complete();

    expect(await firstConnect, isTrue);
    await disconnect;
    expect(await latestConnect, isTrue);
    expect(events, [
      'connect-1-start',
      'connect-1-end',
      'disconnect',
      'connect-3',
    ]);
  });

  test('a failed transition does not poison later transitions', () async {
    final queue = ConnectionTransitionQueue();

    await expectLater(
      queue.run<void>(() async => throw StateError('failed')),
      throwsStateError,
    );

    expect(await queue.run(() async => 42), 42);
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test('a failed operation does not poison later queued operations', () async {
    final queue = RecoveringSerialQueue();
    final calls = <String>[];

    await expectLater(
      queue.add(() async {
        calls.add('failed');
        throw StateError('disk full');
      }),
      throwsStateError,
    );
    await queue.add(() async => calls.add('recovered'));
    await queue.flush();

    expect(calls, const ['failed', 'recovered']);
  });

  test('flush reports the latest save failure until a later save succeeds',
      () async {
    final queue = RecoveringSerialQueue();

    await expectLater(
      queue.add(() async => throw StateError('disk full')),
      throwsStateError,
    );
    await expectLater(queue.flush(), throwsStateError);

    await queue.add(() async {});
    await queue.flush();
  });

  test('pending barrier reports a write that fails while it is waiting',
      () async {
    final queue = RecoveringSerialQueue();
    final release = Completer<void>();
    final operation = queue.add(() async {
      await release.future;
      throw StateError('disk full');
    });
    final barrier = queue.waitForPendingOperations();

    release.complete();

    await expectLater(operation, throwsStateError);
    await expectLater(barrier, throwsStateError);
  });

  test('completed failure does not poison a later pending-write barrier',
      () async {
    final queue = RecoveringSerialQueue();

    await expectLater(
      queue.add(() async => throw StateError('disk full')),
      throwsStateError,
    );

    await queue.waitForPendingOperations();
    await expectLater(queue.flush(), throwsStateError);
  });
}

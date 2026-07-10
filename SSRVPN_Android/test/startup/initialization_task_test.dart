import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/startup/initialization_task.dart';

void main() {
  test('reuses an initialization that is still running', () async {
    final task = InitializationTask();
    final completer = Completer<void>();
    var starts = 0;

    Future<void> initialize() {
      starts += 1;
      return completer.future;
    }

    final first = task.run(initialize);
    final second = task.run(initialize);

    expect(starts, 1);
    completer.complete();
    await Future.wait([first, second]);
  });

  test('allows a fresh attempt after the previous attempt finishes', () async {
    final task = InitializationTask();
    var starts = 0;

    await task.run(() async => starts += 1);
    await task.run(() async => starts += 1);

    expect(starts, 2);
  });

  test('allows a fresh attempt after an initialization error', () async {
    final task = InitializationTask();
    var starts = 0;

    await expectLater(
      task.run(() async {
        starts += 1;
        throw StateError('failed');
      }),
      throwsStateError,
    );
    await task.run(() async => starts += 1);

    expect(starts, 2);
  });
}

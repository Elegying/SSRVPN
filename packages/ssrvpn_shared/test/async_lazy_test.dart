import 'dart:async';

import 'package:ssrvpn_shared/utils/async_lazy.dart';
import 'package:test/test.dart';

void main() {
  group('AsyncLazy', () {
    test('shares one in-flight initialization across concurrent callers',
        () async {
      final lazy = AsyncLazy<Object>();
      final gate = Completer<void>();
      var calls = 0;

      Future<Object> create() async {
        calls++;
        await gate.future;
        return Object();
      }

      final first = lazy.get(create);
      final second = lazy.get(create);
      gate.complete();

      expect(await first, same(await second));
      expect(calls, 1);
    });

    test('retries after initialization fails', () async {
      final lazy = AsyncLazy<int>();
      var calls = 0;

      Future<int> create() async {
        calls++;
        if (calls == 1) throw StateError('first attempt failed');
        return 42;
      }

      await expectLater(lazy.get(create), throwsStateError);
      expect(await lazy.get(create), 42);
      expect(calls, 2);
    });

    test('reset does not let an older failure clear a newer attempt', () async {
      final lazy = AsyncLazy<int>();
      final oldGate = Completer<int>();

      final oldAttempt = lazy.get(() => oldGate.future);
      lazy.reset();
      final newAttempt = lazy.get(() async => 7);
      oldGate.completeError(StateError('stale failure'));

      await expectLater(oldAttempt, throwsStateError);
      expect(await newAttempt, 7);
      expect(await lazy.get(() async => 9), 7);
    });
  });
}

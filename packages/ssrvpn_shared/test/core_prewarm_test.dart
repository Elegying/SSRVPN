import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/utils/core_prewarm.dart';

void main() {
  test('asset preparation works when prewarming is disabled', () async {
    var prepared = false;
    await prepareAssetsWithCorePrewarm(prepareAssets: () async {
      prepared = true;
    });
    expect(prepared, isTrue);
  });

  test('prewarm overlaps asset preparation but readiness waits for both',
      () async {
    final warm = Completer<void>();
    final assets = Completer<void>();
    var warmStarted = false;
    var assetsStarted = false;
    var ready = false;
    final operation = prepareAssetsWithCorePrewarm(
      prewarmCore: () {
        warmStarted = true;
        return warm.future;
      },
      prepareAssets: () {
        assetsStarted = true;
        return assets.future;
      },
    ).then((_) => ready = true);
    expect(warmStarted, isTrue);
    expect(assetsStarted, isTrue);
    warm.complete();
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    assets.complete();
    await operation;
    expect(ready, isTrue);
  });

  test('failed prewarm waits for asset cleanup and propagates the error',
      () async {
    final warm = Completer<void>();
    final assets = Completer<void>();
    final operation = prepareAssetsWithCorePrewarm(
      prewarmCore: () => warm.future,
      prepareAssets: () => assets.future,
    );
    final failure = expectLater(operation, throwsStateError);
    var completed = false;
    operation.then<void>((_) => completed = true,
        onError: (Object _, StackTrace __) => completed = true);
    warm.completeError(StateError('core probe failed'));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    assets.complete();
    await failure;
  });
}

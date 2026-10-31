import 'dart:async';

/// Runs a bounded, non-connecting core probe alongside independent asset work.
/// Neither task permits a connection until both have finished.
Future<void> prepareAssetsWithCorePrewarm({
  required Future<void> Function() prepareAssets,
  Future<void> Function()? prewarmCore,
}) async {
  await Future.wait([
    if (prewarmCore != null) Future.sync(prewarmCore),
    Future.sync(prepareAssets),
  ]);
}

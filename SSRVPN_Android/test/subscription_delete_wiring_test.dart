import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android subscription deletion preserves shared rollback semantics', () {
    final source =
        File('lib/screens/subscription_screen.dart').readAsStringSync();

    expect(source, isNot(contains('continueAfterRefreshFailure: true')));
    expect(source, isNot(contains('订阅已删除，但剩余订阅刷新失败')));
  });

  test('Android deletion stops once and clears only the native snapshot', () {
    final source =
        File('lib/screens/subscription_screen.dart').readAsStringSync();
    final stopStart = source.indexOf('stopClash: () async {');
    final snapshotStart = source.indexOf('onNoRunnableNodes: () async {');
    final callEnd = source.indexOf('\n        );', snapshotStart);

    expect(stopStart, greaterThanOrEqualTo(0));
    expect(snapshotStart, greaterThan(stopStart));
    expect(callEnd, greaterThan(snapshotStart));

    final stopTransaction = source.substring(stopStart, snapshotStart);
    expect(stopTransaction, contains('requestConnectionIntent(false)'));
    expect(RegExp(r'await clashService\.stop\(\)').allMatches(stopTransaction),
        hasLength(1));

    final snapshotTransaction = source.substring(snapshotStart, callEnd);
    expect(snapshotTransaction, contains('clearNativeConnectionSnapshot'));
    expect(snapshotTransaction, isNot(contains('clashService.stop')));
  });

  test('Android deletion cancels a pending connection start', () {
    final source =
        File('lib/screens/subscription_screen.dart').readAsStringSync();

    final stopStart = source.indexOf('stopClash: () async {');
    final stopEnd = source.indexOf('onNoRunnableNodes:', stopStart);
    final stopTransaction = source.substring(stopStart, stopEnd);

    expect(
        stopTransaction, contains('final wasRunning = clashService.isRunning'));
    expect(stopTransaction, contains('clashService.connectionDesired'));
    expect(stopTransaction,
        contains('clashService.nativeConnectionTransitioning'));
    expect(stopTransaction, contains('requestConnectionIntent(false)'));
    expect(stopTransaction, contains('return wasRunning'));
    expect(source, isNot(contains('clashRunning:')));
  });
}

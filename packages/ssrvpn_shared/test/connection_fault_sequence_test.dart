import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final tun in [false, true]) {
    test(
        'DNS and IPv6 target failures keep the $tun connection and clear on success',
        () async {
      final core = _FaultCore()..updateSettings(AppSettings(enableTun: tun));
      addTearDown(core.dispose);
      core.requestConnectionIntent(true);
      core.setRunning(true);
      core.startStatusMonitor();
      await core.started.first.future;
      for (final failure in [
        const SocketException('DNS lookup failed'),
        const SocketException('[SSRVPN_IPV6_TARGET_FAILED] unreachable'),
        TimeoutException('temporary mobile path loss'),
      ]) {
        await core.verifyUserConnectivity(
            maxAttempts: 1, request: (_) async => throw failure);
        expect(core.connectivityWarning, isNotNull);
        expect(core.connectionStatusWarning, isNull);
        expect(core.isRunning, isTrue);
        expect(core.connectionDesired, isTrue);
      }
      await core.verifyUserConnectivity(
          maxAttempts: 1, request: (_) async => http.Response('', 204));
      expect(core.connectivityWarning, isNull);
      expect(core.stopCalls, 0);
      expect(core.recoveryCalls, 0);
      expect(core.recentLogs, contains('保留当前连接'));
      core.answers.first.complete(true);
      await core.started[1].future;
      expect(core.connectionStatusWarning, isNull);
      expect(core.isRunning, isTrue);
    });
  }

  test(
      'two failures separated by healthy samples never accumulate into restart',
      () async {
    final core = _FaultCore();
    addTearDown(core.dispose);
    core.requestConnectionIntent(true);
    core.setRunning(true);
    await core.verifyUserConnectivity(
        maxAttempts: 1, request: (_) async => http.Response('', 502));
    core.startStatusMonitor();
    const samples = [false, false, true, false, false, true];
    for (var i = 0; i < samples.length; i++) {
      await core.started[i].future;
      core.answers[i].complete(samples[i]);
      await core.started[i + 1].future;
      expect(core.isRunning, isTrue);
      expect(core.connectionDesired, isTrue);
      expect(core.connectionStatusWarning, isNull);
      expect(core.recoveryCalls, 0);
      expect(core.stopCalls, 0);
    }
    expect(core.lastHealthCheckError, isNull);
    expect(core.recentLogs, contains('[health_recovered]'));
  });

  test('external advisory cannot hide sustained control-plane failure',
      () async {
    final core = _FaultCore();
    addTearDown(core.dispose);
    core.requestConnectionIntent(true);
    core.setRunning(true);
    await core.verifyUserConnectivity(
        maxAttempts: 1, request: (_) async => http.Response('', 503));
    core.startStatusMonitor();
    for (var i = 0; i < 3; i++) {
      await core.started[i].future;
      core.answers[i].complete(false);
    }
    await core.recovered.future.timeout(const Duration(seconds: 2));
    core.stopStatusMonitor();
    expect(core.recoveryCalls, 1);
    expect(core.isRunning, isTrue);
    expect(core.connectionDesired, isTrue);
    expect(core.recentLogs, contains('[health_recovery]'));
  });

  test('network switch then reconnect rejects both late failing observations',
      () async {
    final core = _ObservationCore();
    addTearDown(core.dispose);
    core.requestConnectionIntent(true);
    core.setRunning(true);
    core.fingerprint = 'wifi:192.0.2.1';
    await core.runNetworkChangeCheck();
    core.observeForTest();
    await core.observationsStarted[0].future;
    core.fingerprint = 'mobile:198.51.100.1';
    await core.runNetworkChangeCheck();
    await core.observationsStarted[1].future;
    core.setRunning(false);
    core.requestConnectionIntent(true);
    core.setRunning(true);
    core.observeForTest();
    await core.observationsStarted[2].future;
    core.replies[2].complete(http.Response('', 204));
    await core.finished[2].future;
    core.replies[0].completeError(const SocketException('old DNS failure'));
    core.replies[1].completeError(
        const SocketException('[SSRVPN_IPV6_TARGET_FAILED] old network'));
    await Future.wait(core.finished.take(2).map((done) => done.future));
    expect(core.observationCalls, 3);
    expect(core.connectivityWarning, isNull);
    expect(core.connectionStatusWarning, isNull);
    expect(core.isRunning, isTrue);
    expect(core.connectionDesired, isTrue);
    expect(core.stopCalls, 0);
    expect(core.recentLogs, isNot(contains('old DNS failure')));
    expect(core.recentLogs, isNot(contains('old network')));
  });
}

class _FaultCore extends ClashServiceBase {
  final answers = List.generate(8, (_) => Completer<bool>());
  final started = List.generate(8, (_) => Completer<void>());
  final recovered = Completer<void>();
  int healthCalls = 0;
  int recoveryCalls = 0;
  int stopCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 10);
  @override
  Duration get healthFailureGrace => Duration.zero;
  @override
  Duration? get networkChangeWatchInterval => null;
  @override
  Future<void> refreshRuleProvidersOnce() async {}
  @override
  Future<bool> healthCheck() async {
    final index = healthCalls++;
    started[index].complete();
    final healthy = await answers[index].future;
    setLastHealthCheckError(healthy ? null : 'CORE_API_UNAVAILABLE: fixture');
    return healthy;
  }

  @override
  Future<bool> recoverAfterHealthCheckFailure(int generation) async {
    recoveryCalls++;
    setRunning(true, newSession: true);
    recovered.complete();
    return true;
  }

  @override
  Future<void> onStopRequired() async {
    stopCalls++;
    setRunning(false);
  }

  // These tests do not run diagnostics; accidental use must not report success.
  @override
  Future<bool> diagnosticCoreAvailable() => throw UnsupportedError('fixture');
  @override
  String get diagnosticConfigPath => throw UnsupportedError('fixture');
  @override
  bool get diagnosticConfigRequired => throw UnsupportedError('fixture');
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() =>
      throw UnsupportedError('fixture');
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) =>
      throw UnsupportedError('fixture');
}

class _ObservationCore extends _FaultCore {
  final replies = List.generate(3, (_) => Completer<http.Response>());
  final finished = List.generate(3, (_) => Completer<void>());
  final observationsStarted = List.generate(3, (_) => Completer<void>());
  int observationCalls = 0;
  String? fingerprint;

  void observeForTest() => scheduleDataPlaneObservation();

  @override
  Future<String?> buildNetworkFingerprint() async => fingerprint;
  @override
  Future<void> observeDataPlaneHealth() async {
    final index = observationCalls++;
    final generation = captureAutomaticRestartIntent();
    observationsStarted[index].complete();
    await verifyUserConnectivity(
      maxAttempts: 1,
      request: (_) => replies[index].future,
      shouldContinue: () =>
          isRunning &&
          isDataPlaneObservationCurrent &&
          generation == captureAutomaticRestartIntent(),
    );
    finished[index].complete();
  }
}

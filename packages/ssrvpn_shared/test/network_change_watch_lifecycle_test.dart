import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

class _WatchService extends ClashServiceBase {
  final queries = <Completer<String?>>[];
  int observations = 0;

  @override
  Future<String?> buildNetworkFingerprint() {
    final query = Completer<String?>();
    queries.add(query);
    return query.future;
  }

  void restartWatch() {
    stopNetworkChangeWatch();
    setRunning(false);
    setRunning(true);
    startNetworkChangeWatch();
  }

  @override
  Future<void> observeDataPlaneHealth() async => observations++;
  @override
  Future<void> onStopRequired() async => setRunning(false);
  @override
  Future<bool> diagnosticCoreAvailable() async => false;
  @override
  String get diagnosticConfigPath => configPath;
  @override
  bool get diagnosticConfigRequired => false;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: 'test capability');
}

void main() {
  test('old interface enumeration cannot block or reset a restarted watch',
      () async {
    final service = _WatchService()..setRunning(true);
    addTearDown(service.dispose);
    final baseline = service.runNetworkChangeCheck();
    service.queries.single.complete('wifi:10.0.0.2');
    await baseline;
    final oldCheck = service.runNetworkChangeCheck();
    service.restartWatch();
    final currentCheck = service.runNetworkChangeCheck();
    expect(service.queries.length, 3,
        reason: 'the replacement watch must not wait for an old OS query');
    service.queries[1].complete('wifi:10.0.0.3');
    await oldCheck;
    await service.runNetworkChangeCheck();
    expect(service.queries.length, 3,
        reason: 'old completion must not release the current in-flight query');
    service.queries[2].complete('ethernet:192.168.0.2');
    await currentCheck;
    expect(service.observations, 0,
        reason: 'an old result must not seed the replacement baseline');

    final unchanged = service.runNetworkChangeCheck();
    service.queries.last.complete('ethernet:192.168.0.2');
    await unchanged;
    expect(service.observations, 0);
    final changed = service.runNetworkChangeCheck();
    service.queries.last.complete('ethernet:192.168.0.3');
    await changed;
    expect(service.observations, 1);
  });

  test(
      'an enumeration completed after disconnect cannot become the next baseline',
      () async {
    final service = _WatchService()..setRunning(true);
    addTearDown(service.dispose);
    final oldCheck = service.runNetworkChangeCheck();
    service.stopStatusMonitor();
    service.setRunning(false);
    service.queries.single.complete('wifi:10.0.0.2');
    await oldCheck;
    service.setRunning(true);
    final baseline = service.runNetworkChangeCheck();
    service.queries.last.complete('ethernet:192.168.0.2');
    await baseline;
    expect(service.observations, 0);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class _TrafficService extends ClashServiceBase {
  @override
  String get diagnosticConfigPath => '';
  @override
  bool get diagnosticConfigRequired => false;
  @override
  Future<bool> diagnosticCoreAvailable() async => true;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(
          success: false, message: 'Not used by traffic tests');
  @override
  Future<void> onStopRequired() async => setRunning(false);
}

void main() {
  test(
      'authenticated totals include closed connections and reject invalid data',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = _TrafficService()
      ..initHttpClient()
      ..updateSettings(
          AppSettings(apiPort: server.port, apiSecret: 'test-secret'))
      ..setRunning(true);
    addTearDown(service.dispose);
    addTearDown(() => server.close(force: true));
    var invalid = false;
    server.listen((request) async {
      expect(request.uri.path, '/connections');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test-secret');
      request.response.write(jsonEncode({
        'uploadTotal': invalid ? -1 : 1024,
        'downloadTotal': 2048,
        'connections': <Object>[],
      }));
      await request.response.close();
    });
    final first = (await service.readTrafficSample())!;
    expect(first.total, 3072);
    service.setRunning(false);
    expect(await service.readTrafficSample(), isNull);
    service.setRunning(true);
    final next = (await service.readTrafficSample())!;
    expect(next.sessionGeneration, isNot(first.sessionGeneration));
    expect(next.ratesSince(first), (upload: 0.0, download: 0.0));
    invalid = true;
    await expectLater(service.readTrafficSample(), throwsFormatException);
  });

  test('late traffic responses cannot belong to a new connection', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = _TrafficService()
      ..initHttpClient()
      ..updateSettings(AppSettings(apiPort: server.port))
      ..setRunning(true);
    addTearDown(service.dispose);
    addTearDown(() => server.close(force: true));
    final received = Completer<HttpRequest>();
    server.listen(received.complete);
    final pending = service.readTrafficSample();
    final request = await received.future;
    service.setRunning(false);
    service.setRunning(true);
    request.response.write('{"uploadTotal":9999,"downloadTotal":9999}');
    await request.response.close();
    expect(await pending, isNull);
  });
}

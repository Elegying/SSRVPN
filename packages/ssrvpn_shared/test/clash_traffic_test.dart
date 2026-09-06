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
      'authenticated proxy totals survive closed connections and reject invalid data',
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
    var legacyOnly = false;
    var coreGeneration = 1;
    server.listen((request) async {
      expect(request.uri.path, '/ssrvpn/traffic');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test-secret');
      request.response.write(jsonEncode({
        'sessionGeneration': coreGeneration,
        'sampledAtMillis': 2000,
        if (!legacyOnly) 'upload': invalid ? -1 : 1024,
        if (!legacyOnly) 'download': 2048,
        'uploadTotal': 99999999,
        'downloadTotal': 99999999,
        'connections': <Object>[],
      }));
      await request.response.close();
    });
    final first = (await service.readTrafficSample())!;
    expect(first.total, 3072);
    service.setRunning(false);
    expect(await service.readTrafficSample(), isNull);
    coreGeneration++;
    service.setRunning(true);
    final next = (await service.readTrafficSample())!;
    expect(next.sessionGeneration, isNot(first.sessionGeneration));
    expect(next.ratesSince(first), (upload: 0.0, download: 0.0));
    invalid = true;
    await expectLater(service.readTrafficSample(), throwsFormatException);
    legacyOnly = true;
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
    request.response.write(
        '{"sessionGeneration":1,"sampledAtMillis":100,"upload":9999,"download":9999}');
    await request.response.close();
    expect(await pending, isNull);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/clash_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android reads proxy core totals instead of application UID totals',
      () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = ClashService()
      ..initHttpClient()
      ..updateSettings(AppSettings(apiPort: server.port, apiSecret: 'test'))
      ..setRunning(true);
    addTearDown(service.dispose);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/ssrvpn/traffic');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test');
      request.response.write(jsonEncode({
        'sessionGeneration': 7,
        'sampledAtMillis': 1234,
        'upload': 1024,
        'download': 2048,
      }));
      await request.response.close();
    });
    final first = (await service.readTrafficSample())!;
    expect(first.sessionGeneration, 7);
    expect(first.total, 3072);
    service.setRunning(false);
    expect(await service.readTrafficSample(), isNull);
  });
}

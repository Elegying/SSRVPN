import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/http_client_adapter.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test('AdapterResponse stores status, headers, and body bytes', () {
    final response = AdapterResponse(
      statusCode: 204,
      headers: const {'x-test': 'ok'},
      bodyBytes: utf8.encode('done'),
    );

    expect(response.statusCode, 204);
    expect(response.headers['x-test'], 'ok');
    expect(utf8.decode(response.bodyBytes), 'done');
  });

  test('RealHttpClientAdapter reads status, headers, and body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final requestSeen = Completer<void>();
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.userAgentHeader),
        AppConstants.appUserAgent,
      );
      expect(
        request.headers.value(HttpHeaders.acceptHeader),
        'text/yaml, application/x-yaml, */*',
      );
      expect(
          request.headers.value(HttpHeaders.acceptEncodingHeader), 'identity');

      request.response.statusCode = HttpStatus.created;
      request.response.headers.set('x-profile-title', 'Local Profile');
      request.response.write('subscription-body');
      await request.response.close();
      requestSeen.complete();
    });

    final adapter = RealHttpClientAdapter(
      connectTimeout: const Duration(seconds: 2),
      readTimeout: const Duration(seconds: 2),
      allowBadCertificates: true,
    );

    final response = await adapter.get(
      Uri.parse('http://127.0.0.1:${server.port}/sub.yaml'),
      timeout: const Duration(seconds: 2),
    );

    expect(response.statusCode, HttpStatus.created);
    expect(response.headers['x-profile-title'], 'Local Profile');
    expect(utf8.decode(response.bodyBytes), 'subscription-body');
    await requestSeen.future.timeout(const Duration(seconds: 2));
  });
}

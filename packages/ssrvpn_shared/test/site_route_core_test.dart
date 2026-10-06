import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/site_access_diagnostic.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test(
      'bundled core reports the actual proxy and reject rule for diagnostic GET',
      () async {
    final folder = await Directory.systemTemp.createTemp('ssrvpn-site-route-');
    addTearDown(() => folder.delete(recursive: true));
    final core = File('${folder.path}/AtlasCore');
    await core.writeAsBytes(gzip.decode(
        await File('../../SSRVPN_MacOS/assets/AtlasCore.gz').readAsBytes()));
    await Process.run('chmod', ['700', core.path]);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    addTearDown(() async {
      for (final socket in peers) {
        socket.destroy();
      }
      await upstream.close(force: true);
    });
    upstream.listen((request) async {
      expect(request.method, 'CONNECT');
      expect(request.uri.toString(), contains('example.com:80'));
      final socket = await request.response.detachSocket(writeHeaders: false);
      peers.add(socket);
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      var input = '';
      socket.listen((bytes) {
        input += utf8.decode(bytes);
        if (input.contains('\r\n\r\n')) {
          expect(input, startsWith('GET '));
          socket.write(
              'HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n');
          input = '';
        }
      });
    });
    final mixed = await freePort(), api = await freePort();
    final config = File('${folder.path}/config.yaml');
    await config.writeAsString('''
mixed-port: $mixed
external-controller: 127.0.0.1:$api
secret: fixture-secret
allow-lan: false
mode: rule
log-level: info
dns:
  enable: false
proxies:
  - name: fixture-node
    type: http
    server: 127.0.0.1
    port: ${upstream.port}
proxy-groups:
  - name: PROXY
    type: select
    proxies: [fixture-node]
rules:
  - DOMAIN,blocked.example.com,REJECT
  - DOMAIN,example.com,PROXY
  - MATCH,DIRECT
''');
    final process =
        await Process.start(core.path, ['-d', folder.path, '-f', config.path]);
    final log = <String>[];
    process.stdout.transform(utf8.decoder).listen(log.add);
    process.stderr.transform(utf8.decoder).listen(log.add);
    addTearDown(() async {
      process.kill();
      await process.exitCode;
    });
    var ready = false;
    final readinessClient = HttpClient()..findProxy = (_) => 'DIRECT';
    final readinessDeadline = DateTime.now().add(const Duration(seconds: 5));
    try {
      while (DateTime.now().isBefore(readinessDeadline)) {
        try {
          // The API listener can open before the compatible provider is ready.
          // Require the fixture node to be selectable before probing its route.
          final request = await readinessClient
              .getUrl(Uri.parse('http://127.0.0.1:$api/proxies/PROXY'))
              .timeout(const Duration(seconds: 1));
          request.headers.set('Authorization', 'Bearer fixture-secret');
          final response =
              await request.close().timeout(const Duration(seconds: 1));
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 1));
          final group = jsonDecode(body);
          if (response.statusCode == HttpStatus.ok &&
              group is Map &&
              group['now'] == 'fixture-node' &&
              group['all'] is List &&
              (group['all'] as List).contains('fixture-node')) {
            ready = true;
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      readinessClient.close(force: true);
    }
    expect(ready, isTrue, reason: log.join());
    final result = await SiteAccessDiagnostic().inspect(
        Uri.parse('http://example.com'),
        proxyPort: mixed,
        apiPort: api,
        apiHeaders: {'Authorization': 'Bearer fixture-secret'});
    expect(result.succeeded, isTrue,
        reason: '${result.summary}\n${log.join()}');
    expect(result.route?.path, '代理 → fixture-node', reason: log.join());
    expect(result.route?.rule, contains('example.com'));
    final blocked = await SiteAccessDiagnostic().inspect(
        Uri.parse('http://blocked.example.com'),
        proxyPort: mixed,
        apiPort: api,
        apiHeaders: {'Authorization': 'Bearer fixture-secret'});
    expect(blocked.route?.rejected, isTrue, reason: log.join());
    expect(blocked.assessment, startsWith('规则拦截'));
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(seconds: 45)));
}

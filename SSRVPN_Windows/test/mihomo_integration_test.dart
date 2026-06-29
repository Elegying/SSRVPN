import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final coreFile = File('assets${Platform.pathSeparator}mihomo.exe');
  final canRun = Platform.isWindows && coreFile.existsSync();

  test(
    'bundled Mihomo starts and exposes its authenticated API',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn-mihomo-integration-',
      );
      final ports = await _reserveFreePorts(3);
      final configFile = File(
        '${tempDir.path}${Platform.pathSeparator}config.yaml',
      );
      await configFile.writeAsString('''
mixed-port: ${ports[0]}
socks-port: ${ports[1]}
allow-lan: false
mode: direct
log-level: warning
external-controller: '127.0.0.1:${ports[2]}'
secret: 'integration-test-secret'
ipv6: false
dns:
  enable: false
tun:
  enable: false
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
''', flush: true);

      final process = await Process.start(
        coreFile.absolute.path,
        ['-d', tempDir.path, '-f', configFile.path],
      );
      final output = <String>[];
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(output.add);
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(output.add);

      int? exitCode;
      process.exitCode.then((value) => exitCode = value);
      var healthy = false;
      final client = _createDirectHttpClient();
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline) && exitCode == null) {
          try {
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:${ports[2]}/version'),
            );
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer integration-test-secret',
            );
            final response = await request.close().timeout(
                  const Duration(seconds: 2),
                );
            await response.drain<void>();
            if (response.statusCode == HttpStatus.ok) {
              healthy = true;
              break;
            }
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }

        expect(
          healthy,
          isTrue,
          reason: exitCode == null
              ? 'Mihomo API did not become ready. ${output.join('\n')}'
              : 'Mihomo exited with $exitCode. ${output.join('\n')}',
        );
      } finally {
        client.close(force: true);
        process.kill(ProcessSignal.sigterm);
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
        }
        await tempDir.delete(recursive: true);
      }
    },
    skip: canRun ? false : 'Windows Mihomo binary is not available',
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

Future<List<int>> _reserveFreePorts(int count) async {
  final sockets = <ServerSocket>[];
  try {
    for (var i = 0; i < count; i++) {
      sockets.add(
        await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          shared: false,
        ),
      );
    }
    return sockets.map((socket) => socket.port).toList();
  } finally {
    await Future.wait(sockets.map((socket) => socket.close()));
  }
}

HttpClient _createDirectHttpClient() {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 2);
  return client;
}

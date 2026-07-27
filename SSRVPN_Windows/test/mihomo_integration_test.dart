import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/services/subscription_service.dart';
import 'package:yaml/yaml.dart';

void main() {
  final coreFile = File('assets${Platform.pathSeparator}mihomo.exe');
  final canRun = Platform.isWindows && coreFile.existsSync();

  test(
    'subscription import generates a real config and starts authenticated Mihomo',
    () async {
      SubscriptionService.resetInstanceForTesting();
      addTearDown(SubscriptionService.resetInstanceForTesting);
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn-mihomo-integration-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final ports = await _reserveFreePorts(3);
      final subscriptionServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      addTearDown(() => subscriptionServer.close(force: true));
      subscriptionServer.listen((request) async {
        request.response
          ..headers.contentType = ContentType.text
          ..write('''
proxies:
  - name: Integration Node
    type: ss
    server: 127.0.0.1
    port: 9
    cipher: aes-128-gcm
    password: integration-node-password
''');
        await request.response.close();
      });
      final subscription = await SubscriptionService.getInstance(tempDir.path);
      await subscription.addSubscription(
        'Integration feed',
        'http://127.0.0.1:${subscriptionServer.port}/subscription',
      );
      await subscription.refreshAllSubscriptions();
      expect(subscription.allNodes.single.name, 'Integration Node');

      const apiSecret = 'integration-test-secret';
      final settings = AppSettings(
        proxyPort: ports[0],
        socksPort: ports[1],
        apiPort: ports[2],
        apiSecret: apiSecret,
        enableTun: false,
      );
      final generatedConfig = ClashService().generateClashConfig(
        subscription.rawYaml!,
        settings,
        preferredNodeName: 'Integration Node',
      );
      final parsed = loadYaml(generatedConfig) as YamlMap;
      expect(parsed['external-controller'], '127.0.0.1:${ports[2]}');
      expect(parsed['secret'], apiSecret);
      expect(
        (parsed['proxies'] as YamlList).single['name'],
        'Integration Node',
      );
      final configFile = File(
        '${tempDir.path}${Platform.pathSeparator}config.yaml',
      );
      await configFile.writeAsString(generatedConfig, flush: true);

      final process = await Process.start(
        coreFile.absolute.path,
        ['-d', tempDir.path, '-f', configFile.path],
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigterm);
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
        }
      });
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
              'Bearer $apiSecret',
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

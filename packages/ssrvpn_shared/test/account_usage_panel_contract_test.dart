import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  final panelSource = Platform.environment['SSRVPN_PANEL_SOURCE'];
  test('real panel HTTPS response reaches actionable client maintenance state',
      () async {
    final process = await Process.start('python3', ['-u', '-c', _panelFixture],
        workingDirectory: panelSource);
    unawaited(process.stderr.drain<void>());
    final output = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    addTearDown(() async {
      process.stdin.writeln('stop');
      await process.stdin.flush();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      await output.cancel();
      await process.stdin.close();
    });
    expect(
        await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    final fixture = jsonDecode(output.current) as Map<String, dynamic>;
    final providers = AccountUsageProviders.fromJson(jsonEncode([
      {
        'id': 'fixture',
        'origin': 'https://localhost:${fixture['port']}',
        'nodes': [
          {
            'id': 'fixture',
            'server': 'synthetic.ssrvpn.vip',
            'port': 443,
            'protocol': 'hysteria2'
          }
        ]
      }
    ]));
    final node = ProxyNode(
        name: '自定义名称',
        type: 'hysteria2',
        server: 'synthetic.ssrvpn.vip',
        port: 443,
        extra: {'password': fixture['credential']});
    final identity = providers.resolve(node)!;
    final trusted = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(fixture['certificate'] as String);
    final client =
        AccountUsageClient(createClient: () => HttpClient(context: trusted));
    expect((await client.fetch(identity)).usedBytes, 0);
    Future<void> command(String value) async {
      process.stdin.writeln(value);
      await process.stdin.flush();
      expect(
          await output.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      expect(output.current, 'ok');
    }

    await command('maintenance');
    final renamed = providers.resolve(node.copyWith(name: '再次改名'))!;
    expect(renamed.key, identity.key);
    await expectLater(
        client.fetch(renamed),
        throwsA(isA<UsageQueryFailure>()
            .having((e) => e.kind, 'specific cause',
                UsageFailureKind.nodeMaintenance)
            .having((e) => e.userMessage, 'next step', contains('手动选择其他节点'))));
    final invalid = providers
        .resolve(node.copyWith(extra: {'password': 'invalid-synthetic'}))!;
    await expectLater(
        client.fetch(invalid),
        throwsA(isA<UsageQueryFailure>().having((e) => e.kind,
            'identity checked first', UsageFailureKind.rejected)));
    await command('external-recovery');
    expect((await client.fetch(renamed)).onlineDevices, 0);
    await command('maintenance');
    await expectLater(
        client.fetch(renamed),
        throwsA(isA<UsageQueryFailure>().having(
            (e) => e.kind,
            'new stop needs new recovery evidence',
            UsageFailureKind.nodeMaintenance)));
    await command('resume');
    expect((await client.fetch(renamed)).onlineDevices, 0);
  },
      skip: panelSource == null
          ? 'Requires SSRVPN_PANEL_SOURCE checkout'
          : false);
}

// Disposable, loopback-only service. No operator configuration or VPN process.
const _panelFixture = r'''
import json, secrets, ssl, subprocess, sys, tempfile, threading
from pathlib import Path
from types import SimpleNamespace
import hysteria2_panel as panel
from tests.test_panel import PolicyStatsClient
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    certificate, key = root / 'server.crt', root / 'server.key'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', str(key), '-out', str(certificate), '-days', '1',
        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
        '-addext', 'basicConstraints=critical,CA:TRUE',
        '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
        '-addext', 'extendedKeyUsage=serverAuth'],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    database = panel.Database(root / 'panel.db', secrets.token_bytes(32))
    database.initialize()
    credential = secrets.token_urlsafe(24)
    database.create_proxy_user('fixture', token=credential)
    stats = PolicyStatsClient()
    manager = panel.UsageManager(database, stats)
    manager.collect_once()
    app = panel.PanelApplication(database, 'synthetic.ssrvpn.vip', 443, 'a' * 64,
        stats, usage_manager=manager)
    service_state = ['active']
    def service_runner(command, **_kwargs):
        if command[1] != 'is-active':
            service_state[0] = 'inactive' if command[3] == 'stop' else 'active'
        return SimpleNamespace(returncode=0, stdout=service_state[0] + '\n')
    app.service_controller.runner = service_runner
    server = panel.make_panel_server(('127.0.0.1', 0), app)
    server.tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.tls_context.load_cert_chain(certificate, key)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    print(json.dumps({'port': server.server_port, 'credential': credential,
        'certificate': str(certificate)}), flush=True)
    try:
        for command in sys.stdin:
            command = command.strip()
            if command == 'stop': break
            if command == 'maintenance':
                app.service_controller.action('stop')
                manager._record_health(False)
            elif command == 'resume': app.service_controller.action('start')
            elif command == 'external-recovery': service_state[0] = 'active'
            else: raise ValueError('unknown fixture command')
            if service_state[0] == 'active': manager.collect_once()
            print('ok', flush=True)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(3)
''';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/macos_tun_rule_staging.dart';

final _macosRoot =
    File('assets/macos_tun_runner.sh').existsSync() ? '.' : 'SSRVPN_MacOS';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp("ssrvpn rules '");
  });
  tearDown(() => root.delete(recursive: true));

  test(
      'staged versioned rules survive runtime relocation and load in real core',
      () async {
    final assets =
        Directory('$_macosRoot/../packages/ssrvpn_shared/assets/rules/latest');
    final manifest =
        jsonDecode(File('${assets.path}/manifest.json').readAsStringSync());
    final providers = <String, dynamic>{};
    final rules = <String>[];
    for (final item in manifest['files'] as List<dynamic>) {
      final entry = item as Map<String, dynamic>;
      if (entry['behavior'] == 'packages') continue;
      final name = entry['name'] as String;
      final relative = 'providers/bundles/${manifest['version']}/$name';
      final file = File('${root.path}/$relative');
      file.parent.createSync(recursive: true);
      File('${assets.path}/$name').copySync(file.path);
      providers[name] = {
        'type': 'file',
        'behavior': entry['behavior'],
        'format': 'yaml',
        'path': './$relative'
      };
      rules.add('RULE-SET,$name,DIRECT');
    }
    final port = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final apiPort = port.port;
    await port.close();
    final config = utf8.encode(jsonEncode({
      'mixed-port': 0,
      'external-controller': '127.0.0.1:$apiPort',
      'secret': 'staging-test',
      'mode': 'rule',
      'rule-providers': providers,
      'rules': [...rules, 'MATCH,DIRECT'],
      'tun': {'enable': false},
      'dns': {'enable': false},
    }));
    final staging = await buildTunRuleStagingScript(config, root.path);
    final stage = Directory('${root.path}/stage')..createSync();
    final runtime = Directory('${root.path}/runtime')..createSync();
    await _runStaging(staging, stage);
    final runner =
        File('$_macosRoot/assets/macos_tun_runner.sh').readAsStringSync();
    final copy = runner.substring(
        runner.indexOf('if [[ -d "\$script_dir/providers" ]]'),
        runner.indexOf('\nTMPDIR="\$runtime_dir/tmp"'));
    final copied = await Process.run('/bin/bash', [
      '-c',
      'set -euo pipefail\n/bin/mkdir "\$runtime_dir/providers"\n$copy'
    ], environment: {
      'script_dir': stage.path,
      'runtime_dir': runtime.path
    });
    expect(copied.exitCode, 0, reason: '${copied.stderr}');
    for (final provider in providers.values) {
      final path = provider['path'] as String;
      expect(File('${runtime.path}/$path').readAsBytesSync(),
          File('${root.path}/$path').readAsBytesSync());
    }
    final executable = File('${root.path}/core')
      ..writeAsBytesSync(gzip
          .decode(File('$_macosRoot/assets/AtlasCore.gz').readAsBytesSync()));
    expect((await Process.run('/bin/chmod', ['700', executable.path])).exitCode,
        0);
    File('${runtime.path}/config.yaml').writeAsBytesSync(config);
    final core = await Process.start(executable.path,
        ['-d', runtime.path, '-f', '${runtime.path}/config.yaml']);
    final output = StringBuffer();
    core.stdout.transform(utf8.decoder).listen(output.write);
    core.stderr.transform(utf8.decoder).listen(output.write);
    final client = HttpClient();
    try {
      Map<String, dynamic>? loaded;
      for (var attempt = 0; attempt < 100; attempt++) {
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$apiPort/providers/rules'));
          request.headers.set('Authorization', 'Bearer staging-test');
          final reply = await request.close();
          final data = jsonDecode(await utf8.decoder.bind(reply).join());
          loaded = data['providers'] as Map<String, dynamic>?;
          if (loaded != null &&
              providers.keys.every((name) {
                final entry = loaded?[name];
                final count = entry is Map ? entry['ruleCount'] : null;
                return count is int && count > 0;
              })) {
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      for (final name in providers.keys) {
        expect(loaded?[name]?['ruleCount'], greaterThan(0),
            reason: '$name: $output');
      }
    } finally {
      client.close(force: true);
      core.kill();
      await core.exitCode.timeout(const Duration(seconds: 5));
    }
  }, skip: !Platform.isMacOS);

  test('missing, empty and escaping provider paths fail before authorization',
      () async {
    for (final path in [
      './providers/bundles/2.0.1/missing.yaml',
      '../outside.yaml',
      './providers/../outside.yaml'
    ]) {
      await expectLater(buildTunRuleStagingScript(_config(path), root.path),
          throwsFormatException);
    }
    final empty = File('${root.path}/providers/empty.yaml');
    empty.parent.createSync();
    empty.writeAsStringSync('');
    await expectLater(
        buildTunRuleStagingScript(_config('./providers/empty.yaml'), root.path),
        throwsFormatException);
  });

  test('changed provider after authorization preparation fails its hash check',
      () async {
    final file = File('${root.path}/providers/gfw.yaml');
    file.parent.createSync();
    file.writeAsStringSync('payload: [example.com]');
    final script = await buildTunRuleStagingScript(
        _config('./providers/gfw.yaml'), root.path);
    file.writeAsStringSync('payload: [changed.example]');
    final stage = Directory('${root.path}/stage')..createSync();
    final result = await _runStaging(script, stage, expectSuccess: false);
    expect(result.exitCode, 74);
  });

  test('legacy MRS and inline providers remain compatible', () async {
    final file = File('${root.path}/providers/ssrvpn-geosite-gfw.mrs');
    file.parent.createSync();
    file.writeAsBytesSync([1, 2, 3]);
    final script = await buildTunRuleStagingScript(
        _config('./providers/ssrvpn-geosite-gfw.mrs'), root.path);
    final stage = Directory('${root.path}/stage')..createSync();
    await _runStaging(script, stage);
    expect(
        File('${stage.path}/providers/ssrvpn-geosite-gfw.mrs')
            .readAsBytesSync(),
        [1, 2, 3]);
    expect(
        await buildTunRuleStagingScript(
            utf8.encode(
                'rule-providers: {inline: {type: inline, payload: []}}'),
            root.path),
        isEmpty);
  });
}

List<int> _config(String path) => utf8.encode(jsonEncode({
      'rule-providers': {
        'test': {'type': 'file', 'path': path}
      }
    }));

Future<ProcessResult> _runStaging(String script, Directory stage,
    {bool expectSuccess = true}) async {
  // Use the production launcher hash verifier, without authorization or TUN/DNS.
  final launcher = File('$_macosRoot/lib/services/macos_tun_session.dart')
      .readAsStringSync();
  final hash = launcher.substring(launcher.indexOf('check_hash() {'),
      launcher.indexOf('\ncheck_hash "\$stage/macos_tun_runner.sh"'));
  final result = await Process.run(
      '/bin/bash', ['-c', 'set -euo pipefail\numask 077\n$hash\n$script'],
      environment: {'stage': stage.path});
  if (expectSuccess) expect(result.exitCode, 0, reason: '${result.stderr}');
  return result;
}

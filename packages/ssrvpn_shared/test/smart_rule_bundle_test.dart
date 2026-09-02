import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/smart_rule_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('installs a verified baseline without a network dependency', () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final bundle = _bundleFor('payload:\n  - "+.example.com"\n');

    final result = await SmartRuleBundle.ensureInstalled(
      directory.path,
      assetBundle: bundle,
    );

    expect(result.version, '1.0.0');
    expect(result.installedFiles, 1);
    expect(result.reusedFiles, 0);
    expect(
      await File('${directory.path}/providers/example.yaml').readAsString(),
      'payload:\n  - "+.example.com"\n',
    );
  });

  test('retains a valid remotely refreshed provider', () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final providers = Directory('${directory.path}/providers');
    await providers.create(recursive: true);
    final active = File('${providers.path}/example.yaml');
    await active.writeAsString('payload:\n  - "+.newer.example"\n');

    final result = await SmartRuleBundle.ensureInstalled(
      directory.path,
      assetBundle: _bundleFor('payload:\n  - "+.baseline.example"\n'),
    );

    expect(result.installedFiles, 0);
    expect(result.reusedFiles, 1);
    expect(await active.readAsString(), contains('newer.example'));
  });

  test('repairs a malformed cached provider from the bundled baseline',
      () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final providers = Directory('${directory.path}/providers');
    await providers.create(recursive: true);
    final active = File('${providers.path}/example.yaml');
    await active.writeAsString('payload: [broken');

    final result = await SmartRuleBundle.ensureInstalled(
      directory.path,
      assetBundle: _bundleFor('payload:\n  - "+.baseline.example"\n'),
    );

    expect(result.installedFiles, 1);
    expect(await active.readAsString(), contains('baseline.example'));
  });
}

_MemoryAssetBundle _bundleFor(String provider) {
  final bytes = utf8.encode(provider);
  final manifest = jsonEncode({
    'schemaVersion': 1,
    'version': '1.0.0',
    'files': [
      {
        'name': 'example.yaml',
        'behavior': 'domain',
        'sha256': sha256.convert(bytes).toString(),
      },
    ],
  });
  return _MemoryAssetBundle({
    '${SmartRuleBundle.assetPrefix}/manifest.json': utf8.encode(manifest),
    '${SmartRuleBundle.assetPrefix}/example.yaml': bytes,
  });
}

class _MemoryAssetBundle extends CachingAssetBundle {
  _MemoryAssetBundle(this.assets);

  final Map<String, List<int>> assets;

  @override
  Future<ByteData> load(String key) async {
    final bytes = assets[key];
    if (bytes == null) throw StateError('missing asset: $key');
    final data = Uint8List.fromList(bytes);
    return ByteData.view(data.buffer);
  }
}

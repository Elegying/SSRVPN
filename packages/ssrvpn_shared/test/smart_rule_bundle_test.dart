import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/smart_rule_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('installs a verified baseline and persists its active version',
      () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final bundle = _bundleFor('payload:\n  - "+.example.com"\n');

    final result = await SmartRuleBundle.ensureInstalled(
      directory.path,
      assetBundle: bundle,
    );

    expect(result.version, '1.0.0');
    expect(result.activeVersion, '1.0.0');
    expect(result.providerPathPrefix, './providers/bundles/1.0.0');
    expect(result.installedFiles, 1);
    expect(result.reusedFiles, 0);
    expect(
      await File(
        '${directory.path}/providers/bundles/1.0.0/example.yaml',
      ).readAsString(),
      'payload:\n  - "+.example.com"\n',
    );
    expect(
      await SmartRuleBundle.readInstalledVersion(
        directory.path,
        expectedFileNames: {'example.yaml'},
      ),
      '1.0.0',
    );
  });

  test('does not trust an unversioned provider without a verified manifest',
      () async {
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

    expect(result.installedFiles, 1);
    expect(result.reusedFiles, 0);
    expect(result.activeVersion, '1.0.0');
    expect(await active.readAsString(), contains('newer.example'));
    expect(
      await SmartRuleBundle.readInstalledVersion(
        directory.path,
        expectedFileNames: {'example.yaml'},
      ),
      '1.0.0',
    );
  });

  test('migrates a complete legacy active version without downgrading it',
      () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final providers = Directory('${directory.path}/providers');
    await providers.create(recursive: true);
    const remoteProvider = 'payload:\n  - "+.newer.example"\n';
    await File('${providers.path}/example.yaml').writeAsString(remoteProvider);
    final remoteManifest = _manifestFor(
      version: '2.0.0',
      provider: remoteProvider,
    );
    expect(
      await SmartRuleBundle.activateInstalledManifest(
        directory.path,
        remoteManifest,
        expectedFileNames: {'example.yaml'},
      ),
      isTrue,
    );

    final result = await SmartRuleBundle.ensureInstalled(
      directory.path,
      assetBundle: _bundleFor('payload:\n  - "+.baseline.example"\n'),
    );

    expect(result.version, '1.0.0');
    expect(result.activeVersion, '2.0.0');
    expect(result.providerPathPrefix, './providers/bundles/2.0.0');
    expect(
      await File(
        '${directory.path}/providers/bundles/2.0.0/example.yaml',
      ).readAsString(),
      remoteProvider,
    );
  });

  test('replaces an older active version with the bundled baseline', () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final providers = Directory('${directory.path}/providers');
    await providers.create(recursive: true);
    const oldProvider = 'payload:\n  - "+.old.example"\n';
    await File('${providers.path}/example.yaml').writeAsString(oldProvider);
    expect(
      await SmartRuleBundle.activateInstalledManifest(
        directory.path,
        _manifestFor(version: '0.9.0', provider: oldProvider),
        expectedFileNames: {'example.yaml'},
      ),
      isTrue,
    );

    final result = await SmartRuleBundle.ensureInstalled(
      directory.path,
      assetBundle: _bundleFor('payload:\n  - "+.baseline.example"\n'),
    );

    expect(result.activeVersion, '1.0.0');
    expect(result.providerPathPrefix, './providers/bundles/1.0.0');
    expect(
      await File(
        '${directory.path}/providers/bundles/1.0.0/example.yaml',
      ).readAsString(),
      contains('baseline.example'),
    );
  });

  test('repairs a malformed cache and activates the bundled baseline',
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
    expect(await active.readAsString(), contains('broken'));
    expect(
      await File(
        '${directory.path}/providers/bundles/1.0.0/example.yaml',
      ).readAsString(),
      contains('baseline.example'),
    );
    expect(
      await SmartRuleBundle.readInstalledVersion(
        directory.path,
        expectedFileNames: {'example.yaml'},
      ),
      '1.0.0',
    );
  });

  test('tiny version descriptor compares semantic versions and binds manifest',
      () {
    final manifest = _manifestFor(
      version: '1.1.0',
      provider: 'payload:\n  - "+.example.com"\n',
    );
    final descriptor = SmartRuleBundle.parseVersionDescriptor(
      _versionDescriptor('1.1.0', manifest),
    );

    expect(descriptor.isNewerThan(null), isTrue);
    expect(descriptor.isNewerThan('1.0.9'), isTrue);
    expect(descriptor.isNewerThan('1.1.0'), isFalse);
    expect(descriptor.isNewerThan('2.0.0'), isFalse);
    expect(descriptor.acceptsManifest(manifest), isTrue);
    expect(descriptor.acceptsManifest('$manifest '), isFalse);
  });

  test('manifest activation commits only after every provider matches',
      () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final providers = Directory('${directory.path}/providers');
    await providers.create(recursive: true);
    const activeProvider = 'payload:\n  - "+.active.example"\n';
    await File('${providers.path}/example.yaml').writeAsString(activeProvider);
    final oldManifest = _manifestFor(
      version: '1.0.0',
      provider: activeProvider,
    );
    final newManifest = _manifestFor(
      version: '1.1.0',
      provider: 'payload:\n  - "+.different.example"\n',
    );

    expect(
      await SmartRuleBundle.activateInstalledManifest(
        directory.path,
        oldManifest,
        expectedFileNames: {'example.yaml'},
      ),
      isTrue,
    );
    expect(
      await SmartRuleBundle.activateInstalledManifest(
        directory.path,
        newManifest,
        expectedFileNames: {'example.yaml'},
      ),
      isFalse,
    );
    expect(
      await SmartRuleBundle.readInstalledVersion(
        directory.path,
        expectedFileNames: {'example.yaml'},
      ),
      '1.0.0',
    );
  });

  test('verified remote content becomes the durable local provider', () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    final providers = Directory('${directory.path}/providers');
    await providers.create(recursive: true);
    final active = File('${providers.path}/example.yaml');
    await active.writeAsString('payload:\n  - "+.legacy.example"\n');
    const updated = 'payload:\n  - "+.updated.example"\n';
    final manifestText = _manifestFor(version: '1.1.0', provider: updated);
    final manifest = SmartRuleBundle.parseManifest(manifestText);

    expect(
      await SmartRuleBundle.installVerifiedProviderFiles(
        directory.path,
        manifest,
        const {'example.yaml': updated},
      ),
      isTrue,
    );
    expect(await active.readAsString(), contains('legacy.example'));
    expect(
      await File(
        '${directory.path}/providers/bundles/1.1.0/example.yaml',
      ).readAsString(),
      updated,
    );
    expect(
      await SmartRuleBundle.activateInstalledManifest(
        directory.path,
        manifestText,
        expectedFileNames: {'example.yaml'},
      ),
      isTrue,
    );
  });

  test('a staged version cannot replace the active bundle until complete',
      () async {
    final directory = await Directory.systemTemp.createTemp('smart_rules_');
    addTearDown(() => directory.delete(recursive: true));
    const oldProvider = 'payload:\n  - "+.old.example"\n';
    const newProvider = 'payload:\n  - "+.new.example"\n';
    final oldManifestText = _manifestFor(
      version: '1.0.0',
      provider: oldProvider,
    );
    final newManifestText = _manifestFor(
      version: '1.1.0',
      provider: newProvider,
    );
    final oldManifest = SmartRuleBundle.parseManifest(oldManifestText);
    final newManifest = SmartRuleBundle.parseManifest(newManifestText);

    expect(
      await SmartRuleBundle.installVerifiedProviderFiles(
        directory.path,
        oldManifest,
        const {'example.yaml': oldProvider},
      ),
      isTrue,
    );
    expect(
      await SmartRuleBundle.activateInstalledManifest(
        directory.path,
        oldManifestText,
        expectedFileNames: {'example.yaml'},
      ),
      isTrue,
    );
    expect(
      await SmartRuleBundle.installVerifiedProviderFiles(
        directory.path,
        newManifest,
        const {'example.yaml': 'payload:\n  - "+.tampered.example"\n'},
      ),
      isFalse,
    );

    expect(
      await SmartRuleBundle.readInstalledVersion(
        directory.path,
        expectedFileNames: {'example.yaml'},
      ),
      '1.0.0',
    );
    expect(
      await SmartRuleBundle.activateInstalledManifest(
        directory.path,
        newManifestText,
        expectedFileNames: {'example.yaml'},
      ),
      isFalse,
    );
  });

  test('manifest rejects missing or unexpected provider files', () {
    final manifest = _manifestFor(
      version: '1.0.0',
      provider: 'payload:\n  - "+.example.com"\n',
    );

    expect(
      () => SmartRuleBundle.parseManifest(
        manifest,
        expectedFileNames: {'other.yaml'},
      ),
      throwsFormatException,
    );
  });
}

_MemoryAssetBundle _bundleFor(String provider) {
  final manifest = _manifestFor(version: '1.0.0', provider: provider);
  return _MemoryAssetBundle({
    '${SmartRuleBundle.assetPrefix}/manifest.json': utf8.encode(manifest),
    '${SmartRuleBundle.assetPrefix}/example.yaml': utf8.encode(provider),
  });
}

String _manifestFor({required String version, required String provider}) {
  final bytes = utf8.encode(provider);
  return jsonEncode({
    'schemaVersion': 1,
    'version': version,
    'files': [
      {
        'name': 'example.yaml',
        'behavior': 'domain',
        'count': RegExp(r'^  - ', multiLine: true).allMatches(provider).length,
        'sha256': sha256.convert(bytes).toString(),
      },
    ],
  });
}

String _versionDescriptor(String version, String manifest) => jsonEncode({
      'schemaVersion': 1,
      'version': version,
      'manifestSha256': sha256.convert(utf8.encode(manifest)).toString(),
    });

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

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import 'package:ssrvpn_shared/services/smart_rule_bundle.dart';
import 'package:ssrvpn_shared/services/smart_rule_recovery.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final names = AppConstants.smartRuleProviderFiles.values.toSet();
  late Directory root;
  late _StartupService service;
  late String confirmed;
  late Map<String, String> assets;

  Map<String, String> snapshot(String version) {
    final providers = {
      for (final name in names)
        name: name == 'company_asn.yaml'
            ? 'payload:\n  - "192.0.2.0/24"\n'
            : 'payload:\n  - "+.version$version.example"\n',
    };
    return {
      ...providers,
      'manifest.json': jsonEncode({
        'schemaVersion': 1,
        'version': version,
        'componentVersions': {
          'rules': version,
          'directApps': version,
          'proxyApps': version,
        },
        'files': [
          for (final entry in providers.entries)
            {
              'name': entry.key,
              'behavior': entry.key == 'company_asn.yaml' ? 'ipcidr' : 'domain',
              'count': 1,
              'sha256': sha256.convert(utf8.encode(entry.value)).toString(),
            },
        ],
      }),
    };
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('smart_rule_startup_');
    service = _StartupService()
      ..setPaths(configDir: root.path, configPath: '${root.path}/config.yaml');
    final old = snapshot('1.0.0');
    confirmed = old.remove('manifest.json')!;
    final manifest =
        SmartRuleBundle.parseManifest(confirmed, expectedFileNames: names);
    expect(
        await SmartRuleBundle.installVerifiedProviderFiles(
            root.path, manifest, old),
        isTrue);
    expect(
        await SmartRuleBundle.activateInstalledManifest(root.path, confirmed,
            expectedFileNames: names),
        isTrue);
    await File('${root.path}/providers/rule-recovery.json')
        .writeAsString(jsonEncode({
      'confirmed': jsonDecode(confirmed),
      'rejectedThrough': '2.0.0',
    }));
    assets = snapshot('3.0.0');
    for (final name in assets.keys) {
      rootBundle.evict('${SmartRuleBundle.assetPrefix}/$name');
    }
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets',
        (message) async {
      final key = utf8.decode(message!.buffer
          .asUint8List(message.offsetInBytes, message.lengthInBytes));
      final name = key.split('/').last;
      final text = assets[name];
      if (text == null) return null;
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    for (final name in assets.keys) {
      rootBundle.evict('${SmartRuleBundle.assetPrefix}/$name');
    }
    service.dispose();
    await root.delete(recursive: true);
  });

  test('offline startup after rollback accepts a newer bundled version',
      () async {
    await service.prepareRules();
    expect(service.configVersion, '3.0.0');
    expect(
        await SmartRuleBundle.readInstalledVersion(root.path,
            expectedFileNames: names),
        '3.0.0');
    expect(await SmartRuleRecovery(root.path).hasConfirmedVersion, isTrue);
    final journal = jsonDecode(
        await File('${root.path}/providers/rule-recovery.json')
            .readAsString()) as Map;
    expect((journal['confirmed'] as Map)['version'], '1.0.0',
        reason:
            'a new bundle must still pass a real core start before confirmation');
  });

  for (final version in ['1.5.0', '2.0.0']) {
    test('startup never reinstalls rejected bundled version $version',
        () async {
      assets = snapshot(version);
      await service.prepareRules();
      expect(service.configVersion, '1.0.0');
      expect(
          await SmartRuleBundle.readInstalledVersion(root.path,
              expectedFileNames: names),
          '1.0.0');
      expect(
          await Directory('${root.path}/providers/bundles/$version').exists(),
          isFalse);
    });
  }

  test('damaged newer bundled assets preserve the confirmed fallback',
      () async {
    assets['gfw.yaml'] = 'payload: [broken';
    await service.prepareRules();
    expect(service.configVersion, '1.0.0');
    expect(service.hasLocalSmartRules, isTrue);
    expect(
        await SmartRuleBundle.readInstalledVersion(root.path,
            expectedFileNames: names),
        '1.0.0');
  });

  test('new bundled candidate can fail and roll back once without a download',
      () async {
    await service.prepareRules();
    await File(service.configPath).writeAsString(service.config);
    var starts = 0;
    final success = await service.startCandidate(() async {
      starts++;
      if (starts == 1) {
        expect(
            SmartRuleRecovery.configVersion(
                await File(service.configPath).readAsString()),
            '3.0.0');
        service.setLastStartError('CORE_START_RULES: failed to load provider');
        return false;
      }
      expect(service.configVersion, '1.0.0');
      expect(
          SmartRuleRecovery.configVersion(
              await File(service.configPath).readAsString()),
          '1.0.0');
      service.setRunning(true);
      return true;
    });
    expect(success, isTrue);
    expect(starts, 2);
    expect(await SmartRuleRecovery(root.path).rejects('3.0.0'), isTrue);
    service.setRunning(false);
    await service.prepareRules();
    expect(service.configVersion, '1.0.0');
  });

  test('new bundled baseline is confirmed only after successful startup',
      () async {
    await service.prepareRules();
    await File(service.configPath).writeAsString(service.config);
    expect(
        await service.startCandidate(() async {
          service.setRunning(true);
          return true;
        }),
        isTrue);
    final journal = jsonDecode(
        await File('${root.path}/providers/rule-recovery.json')
            .readAsString()) as Map;
    expect((journal['confirmed'] as Map)['version'], '3.0.0');
    expect(journal['rejectedThrough'], '2.0.0');
  });
}

class _StartupService extends ClashServiceBase {
  @override
  String get diagnosticConfigPath => configPath;
  @override
  bool get diagnosticConfigRequired => true;
  @override
  Future<bool> diagnosticCoreAvailable() async => true;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: 'not used');

  Future<void> prepareRules() => ensureBundledSmartRules();

  String? get configVersion => SmartRuleRecovery.configVersion(config);

  Future<bool> startCandidate(Future<bool> Function() attempt) =>
      startWithSmartRuleRecovery(
          attempt, () async => setRunning(false), () => true, configPath);

  String get config => buildClashConfig('''
proxies:
  - name: test
    type: ss
    server: node.example
    port: 443
    cipher: aes-128-gcm
    password: fixture
''', AppSettings(), platformHeader: '# test');

  @override
  Future<void> onStopRequired() async {}
}

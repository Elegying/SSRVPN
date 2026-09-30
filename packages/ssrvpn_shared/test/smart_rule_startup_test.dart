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

  for (final mode in [
    'idle',
    'unknown-native',
    'running',
    'malformed-config'
  ]) {
    test('startup collection handles $mode without changing connection state',
        () async {
      for (var v = 2; v <= 6; v++) {
        final staged = snapshot('$v.0.0');
        final manifestText = staged.remove('manifest.json')!;
        expect(
            await SmartRuleBundle.installVerifiedProviderFiles(
                root.path,
                SmartRuleBundle.parseManifest(manifestText,
                    expectedFileNames: names),
                staged),
            isTrue);
      }
      if (mode == 'unknown-native') service.retentionPaths = null;
      if (mode == 'running') service.setRunning(true);
      if (mode == 'malformed-config') {
        await File(service.configPath).writeAsString('rule-providers: [bad]');
      }
      final notices = <Object>[];
      service.onRuntimeNotice = notices.add;
      await service.prepareRules();
      expect(service.configVersion, '3.0.0');
      expect(service.lastStartError, isNull);
      expect(service.isRunning, mode == 'running');
      expect(notices, isEmpty);
      for (final v in [1, 3, 5, 6]) {
        expect(
            await Directory('${root.path}/providers/bundles/$v.0.0').exists(),
            isTrue);
      }
      for (final v in [2, 4]) {
        expect(
            await Directory('${root.path}/providers/bundles/$v.0.0').exists(),
            mode != 'idle');
      }
      expect(service.retentionReads, mode == 'running' ? 0 : 1);
      service.setRunning(false);
      service.retentionPaths = const [];
      await service.prepareRules();
      expect(service.retentionReads, mode == 'running' ? 0 : 1,
          reason:
              'reinitialization must not collect after producers were admitted');
    });
  }
}

class _StartupService extends ClashServiceBase {
  List<String>? retentionPaths = const [];
  int retentionReads = 0;
  @override
  Future<List<String>?> ruleRetentionConfigPaths() async {
    retentionReads++;
    return retentionPaths;
  }

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

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/smart_rule_bundle.dart';
import 'package:ssrvpn_shared/services/smart_rule_recovery.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory root;
  late SmartRuleRecovery recovery;
  final names = {
    ...AppConstants.smartRuleProviderFiles.values,
    ...SmartRuleBundle.androidFiles
  };
  late String configPath;
  var current = true;
  var running = false;
  String? error;
  var stops = 0;
  final selected = <String>[];

  Future<String> install(String version) async {
    final contents = <String, String>{
      for (final name in AppConstants.smartRuleProviderFiles.values)
        name: name == 'company_asn.yaml'
            ? 'payload:\n  - "10.0.0.0/8"\n'
            : 'payload:\n  - "+.example.com"\n',
      'direct_apps.yaml': 'payload:\n  - "com.domestic.v${version[0]}"\n',
      'proxy_apps.yaml': 'payload:\n  - "com.foreign.v${version[0]}"\n',
    };
    final text = jsonEncode({
      'schemaVersion': 1,
      'version': version,
      'componentVersions': {
        'rules': version,
        'directApps': version,
        'proxyApps': version
      },
      'files': [
        for (final e in contents.entries)
          {
            'name': e.key,
            'behavior': e.key.endsWith('_apps.yaml')
                ? 'packages'
                : e.key == 'company_asn.yaml'
                    ? 'ipcidr'
                    : 'domain',
            'count': 1,
            'sha256': sha256.convert(utf8.encode(e.value)).toString(),
          }
      ]
    });
    final manifest =
        SmartRuleBundle.parseManifest(text, expectedFileNames: names);
    expect(
        await SmartRuleBundle.installVerifiedProviderFiles(
            root.path, manifest, contents),
        isTrue);
    expect(
        await SmartRuleBundle.activateInstalledManifest(root.path, text,
            expectedFileNames: names),
        isTrue);
    final config = ClashConfigGenerator.generateConfig(
        '''
proxies:
  - name: Test
    type: ss
    server: node.example.com
    port: 443
    cipher: aes-128-gcm
    password: ./providers/bundles/$version/ai_services.yaml
''',
        AppSettings(
            forceProxySites: ['proxy.example'],
            forceDirectSites: ['direct.example']),
        smartRuleProviderPathPrefix:
            SmartRuleBundle.providerPathPrefix(version),
        extraRulesBeforeDirect:
            await SmartRuleBundle.androidRules(root.path, version));
    await File(configPath).writeAsString(config);
    return text;
  }

  Future<bool> run(Future<bool> Function() start,
          {Future<void> Function()? stop}) =>
      recovery.run(
        configPath: configPath,
        start: start,
        stopFailedStart: stop ??
            () async {
              stops++;
              running = false;
            },
        isCurrent: () => current,
        isRunning: () => running,
        failureReason: () => error,
        selectVersion: (version) async => selected.add(version),
        log: (_) {},
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rule_recovery_');
    configPath = '${root.path}/config.yaml';
    recovery = SmartRuleRecovery(root.path, fileNames: names);
    current = true;
    running = false;
    error = null;
    stops = 0;
    selected.clear();
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> confirmOld() async {
    await install('1.0.0');
    expect(
        await run(() async {
          running = true;
          return true;
        }),
        isTrue);
    running = false;
    expect(await recovery.hasConfirmedVersion, isTrue);
  }

  for (final detail in ['分流规则文件缺失或不可用', '分流规则文件为空']) {
    test('TUN staging $detail restores the confirmed bundle once', () async {
      await confirmOld();
      await install('2.0.0');
      final missing = File('${root.path}/providers/bundles/2.0.0/gfw.yaml');
      if (detail.contains('为空')) {
        await missing.writeAsString('');
      } else {
        await missing.delete();
      }
      error = 'TUN_RULE_FILES: $detail：providers/bundles/2.0.0/gfw.yaml';
      var starts = 0;
      expect(
          await run(() async {
            starts++;
            running = starts == 2;
            return running;
          }),
          isTrue);
      expect(starts, 2);
      expect(stops, 1);
      expect(selected, ['1.0.0']);
      expect(
          SmartRuleRecovery.configVersion(
              await File(configPath).readAsString()),
          '1.0.0');
      expect(await recovery.rejects('2.0.0'), isTrue);
    });
  }

  test('unclassified TUN read failures do not retire a rule version', () {
    expect(
        SmartRuleRecovery.isRuleLoadFailure(
            'TUN_RULE_FILES: 无法读取分流规则文件：providers/bundles/2.0.0/gfw.yaml'),
        isFalse);
    expect(
        SmartRuleRecovery.isRuleLoadFailure(
            'TUN_RULE_FILES: 分流规则文件缺失或不可用：permission denied'),
        isFalse);
  });

  test(
      'failed candidate retries once with identical manual/node settings and old Android lists',
      () async {
    await confirmOld();
    await install('2.0.0');
    final before = loadYaml(await File(configPath).readAsString()) as Map;
    var starts = 0;
    error = 'CORE_START_RULES: rule providers failed';
    expect(
        await run(() async {
          starts++;
          running = starts == 2;
          return running;
        }),
        isTrue);
    expect(starts, 2);
    expect(stops, 1);
    expect(selected, ['1.0.0']);
    final source = await File(configPath).readAsString();
    expect(SmartRuleRecovery.configVersion(source), '1.0.0');
    expect(source, startsWith('# ssrvpn-direct-apps: com.domestic.v1\n'));
    final after = loadYaml(source) as Map;
    expect(after['proxies'], before['proxies']);
    expect(after['dns'], before['dns']);
    expect(after['rules'], contains('PROCESS-NAME,com.foreign.v1,PROXY'));
    expect(
        after['rules'], isNot(contains('PROCESS-NAME,com.foreign.v2,PROXY')));
    expect(
        (after['rules'] as List)
            .where((r) => (r as String).contains('proxy.example')),
        (before['rules'] as List)
            .where((r) => (r as String).contains('proxy.example')));
    expect(await recovery.rejects('2.0.0'), isTrue);
    expect(await recovery.rejects('2.0.1'), isFalse);
  });

  for (final reason in [
    'permission denied',
    'rule provider failed: permission denied',
    'address already in use',
    '连接已取消',
    'node unreachable',
    'CORE_START_TIMEOUT: slow startup',
    'CORE_API_UNAVAILABLE: API HTTP 503'
  ]) {
    test('ordinary failure does not reject rules: $reason', () async {
      await confirmOld();
      await install('2.0.0');
      error = reason;
      expect(await run(() async => false), isFalse);
      expect(stops, 0);
      expect(await recovery.rejects('2.0.0'), isFalse);
    });
  }

  test('already running does not confirm an unused candidate', () async {
    await confirmOld();
    await install('2.0.0');
    running = true;
    expect(await run(() async => true), isTrue);
    final journal = jsonDecode(
        await File('${root.path}/providers/rule-recovery.json')
            .readAsString()) as Map;
    expect(journal['confirmed']['version'], '1.0.0');
  });

  for (final damaged in [
    '{truncated',
    '{"confirmed":false}',
    '{"rejectedThrough":42}'
  ]) {
    test(
        'a damaged journal is replaced only after a successful start: $damaged',
        () async {
      await install('1.0.0');
      final journal = File('${root.path}/providers/rule-recovery.json');
      await journal.writeAsString(damaged);
      expect(await recovery.hasConfirmedVersion, isFalse);
      expect(await recovery.repairRejectedSelection(), isNull);
      expect(await run(() async => false), isFalse);
      expect(await journal.readAsString(), damaged);
      expect(
          await run(() async {
            running = true;
            return true;
          }),
          isTrue);
      expect(await recovery.hasConfirmedVersion, isTrue);
      expect(jsonDecode(await journal.readAsString())['confirmed']['version'],
          '1.0.0');
    });
  }

  test('recovery does not read damaged candidate application files', () async {
    await confirmOld();
    await install('2.0.0');
    await File('${root.path}/providers/bundles/2.0.0/direct_apps.yaml')
        .delete();
    error = 'CORE_START_RULES: missing';
    var starts = 0;
    expect(await run(() async => ++starts == 2), isTrue);
    final rules = (loadYaml(await File(configPath).readAsString())
        as Map)['rules'] as List;
    expect(rules.first, AppConstants.rejectIpv6Rule);
    expect(rules[1], startsWith('PROCESS-NAME,'));
    expect(rules, contains('PROCESS-NAME,com.foreign.v1,PROXY'));
  });

  test('restoring apps into a config without apps retains IPv6 precedence',
      () async {
    await confirmOld();
    await install('2.0.0');
    final document =
        jsonDecode(jsonEncode(loadYaml(await File(configPath).readAsString())))
            as Map;
    (document['rules'] as List)
        .removeWhere((rule) => (rule as String).startsWith('PROCESS-NAME,'));
    final source = await recovery.rewriteConfig(jsonEncode(document), '1.0.0');
    final rules = (loadYaml(source) as Map)['rules'] as List;
    expect(rules.first, AppConstants.rejectIpv6Rule);
    expect(rules[1], startsWith('PROCESS-NAME,'));
  });

  test('cancellation during cleanup never retries or changes config', () async {
    await confirmOld();
    await install('2.0.0');
    error = 'CORE_START_RULES: missing';
    var starts = 0;
    expect(
        await run(() async {
          starts++;
          return false;
        }, stop: () async {
          current = false;
        }),
        isFalse);
    expect(starts, 1);
    expect(selected, isEmpty);
    expect(
        SmartRuleRecovery.configVersion(await File(configPath).readAsString()),
        '2.0.0');
  });

  test('a failed fallback is not retried again', () async {
    await confirmOld();
    await install('2.0.0');
    error = 'CORE_START_RULES: missing';
    var starts = 0;
    expect(
        await run(() async {
          starts++;
          return false;
        }),
        isFalse);
    expect(starts, 2);
    expect(await recovery.rejects('2.0.0'), isTrue);
  });

  test('a damaged confirmed snapshot does not get used or permit updates',
      () async {
    await confirmOld();
    await install('2.0.0');
    error = 'CORE_START_RULES: missing';
    await File('${root.path}/providers/bundles/1.0.0/ai_services.yaml')
        .writeAsString('broken');
    expect(await recovery.hasConfirmedVersion, isFalse);
    var starts = 0;
    expect(
        await run(() async {
          starts++;
          return false;
        }),
        isFalse);
    expect(starts, 1);
    expect(selected, isEmpty);
  });

  test('restart repairs activation interrupted after rejecting a candidate',
      () async {
    await confirmOld();
    final candidate = await install('2.0.0');
    error = 'CORE_START_RULES: missing';
    var starts = 0;
    await run(() async {
      starts++;
      return starts == 2;
    });
    // Simulate interruption before the active index was restored.
    await SmartRuleBundle.activateInstalledManifest(root.path, candidate,
        expectedFileNames: names);
    final restarted = SmartRuleRecovery(root.path, fileNames: names);
    expect(await restarted.repairRejectedSelection(), '1.0.0');
    expect(
        await SmartRuleBundle.readInstalledVersion(root.path,
            expectedFileNames: names),
        '1.0.0');
    expect(await restarted.rejects('2.0.0'), isTrue);
  });
}

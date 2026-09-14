import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;

import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/services/smart_rule_bundle.dart';
import 'package:ssrvpn_shared/services/smart_rule_signature.dart';
import 'package:ssrvpn_shared/services/smart_rule_recovery.dart';
import 'package:test/test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';

void main() {
  final local = Directory('assets/rules/latest');
  final assets = local.existsSync()
      ? local
      : Directory('packages/ssrvpn_shared/assets/rules/latest');

  test('exports production configs for isolated native routing checks',
      () async {
    final output = Platform.environment['SSRVPN_ROUTING_FIXTURE'];
    if (output == null) return;
    final ports =
        jsonDecode(Platform.environment['SSRVPN_ROUTING_PORTS']!) as Map;
    for (final entry in [
      ('rule', ProxyMode.rule),
      ('global', ProxyMode.global),
      ('fallback', ProxyMode.rule),
      ('recovered', ProxyMode.rule)
    ]) {
      final mode = entry.$2;
      final config = ClashConfigGenerator.generateConfig(
        'proxies: [{name: LocalProxy, type: http, server: 127.0.0.1, port: ${ports['proxy']}}]',
        AppSettings(
            proxyMode: mode,
            proxyPort: ports['mixed'] as int,
            apiPort: ports['api'] as int,
            apiSecret: 'loopback-traffic-test',
            forceProxySites: ['https://manual-proxy.example/%E4%B8%AD?q=a%20b'],
            forceDirectSites: ['google.com']),
        smartRuleProviderPathPrefix:
            entry.$1 == 'fallback' ? null : '$output/providers/bundles/2.0.0',
        tunConfig: 'tun: {enable: false}',
        dnsConfig: 'dns: {enable: false}',
        platformHeader:
            'find-process-mode: off\nhosts:\n  google.com: 127.0.0.1\n  manual-proxy.example: 127.0.0.1\n  youtube.com: 1.1.1.1\n  unclassified.ssrvpn.invalid: 1.1.1.1',
      );
      final outputConfig = entry.$1 == 'recovered'
          ? await SmartRuleRecovery(output).rewriteConfig(config, '2.0.0')
          : config;
      File('$output/${entry.$1}.yaml').writeAsStringSync(outputConfig);
    }
  });

  test('shipped snapshot verifies its signature and rejects tampering',
      () async {
    final text = File('${assets.path}/version.json').readAsStringSync();
    expect(await SmartRuleSignature.verify(text), isTrue);
    final descriptor = jsonDecode(text) as Map<String, dynamic>;
    descriptor['version'] = '999.0.0';
    expect(await SmartRuleSignature.verify(jsonEncode(descriptor)), isFalse);
    descriptor.remove('signature');
    expect(await SmartRuleSignature.verify(jsonEncode(descriptor)), isFalse);
  });

  test('matching hashes cannot authorize injected or unsafe rule content', () {
    for (final entry in [
      ('domain', 'payload:\n  - "+.example.com"\nrules: [MATCH,DIRECT]\n'),
      ('domain', 'payload:\n  - "+.com"\n'),
      ('domain', 'payload:\n  - "*"\n'),
      ('domain', 'payload:\n  - "*.*"\n'),
      ('ipcidr', 'payload:\n  - "0.0.0.0/0"\n'),
      ('packages', 'payload:\n  - com.android.chrome\n'),
      ('packages', 'payload:\n  - "com.test,PROXY"\n'),
    ]) {
      final content = entry.$2;
      final manifest = SmartRuleManifest(version: '3.0.0', files: {
        'candidate.yaml': SmartRuleManifestEntry(
          name: 'candidate.yaml',
          behavior: entry.$1,
          count: 1,
          sha256: crypto.sha256.convert(utf8.encode(content)).toString(),
        ),
      });
      expect(
          SmartRuleBundle.providerContentsMatch(
              manifest, {'candidate.yaml': content}),
          isFalse,
          reason: content);
    }
  });

  test(
      'an intentionally empty application list is valid without allowing empty domain rules',
      () {
    const content = 'payload: []\n';
    final entry = {
      'name': 'direct_apps.yaml',
      'behavior': 'packages',
      'count': 0,
      'sha256': crypto.sha256.convert(utf8.encode(content)).toString()
    };
    final manifest = SmartRuleBundle.parseManifest(jsonEncode({
      'schemaVersion': 1,
      'version': '3.0.0',
      'files': [entry],
    }));
    expect(
        SmartRuleBundle.providerContentsMatch(
            manifest, {'direct_apps.yaml': content}),
        isTrue);
    expect(
        () => SmartRuleBundle.parseManifest(jsonEncode({
              'schemaVersion': 1,
              'version': '3.0.0',
              'files': [
                {...entry, 'name': 'cn.yaml', 'behavior': 'domain'}
              ],
            })),
        throwsFormatException);
  });

  test('Android list activation honors the same limits as download validation',
      () async {
    final root =
        await Directory.systemTemp.createTemp('android_rule_activation_');
    addTearDown(() => root.delete(recursive: true));
    final bundle = await Directory('${root.path}/providers/bundles/3.0.0')
        .create(recursive: true);
    final direct = File('${bundle.path}/direct_apps.yaml');
    final proxy = File('${bundle.path}/proxy_apps.yaml');
    await direct.writeAsString('payload: []\n');
    await proxy.writeAsString(
        'payload:\n${List.generate(100001, (i) => '  - com.test.p$i').join('\n')}\n');
    final rules = await SmartRuleBundle.androidRules(root.path, '3.0.0');
    expect(rules, hasLength(100001));
    expect(rules.last, 'PROCESS-NAME,com.test.p100000,PROXY');
    await direct.writeAsString('payload:\n  - com.test.p0\n');
    await expectLater(SmartRuleBundle.androidRules(root.path, '3.0.0'),
        throwsFormatException);
    await direct.writeAsString('payload: []\n');
    await proxy.writeAsString('payload:\n  - "com.test,REJECT"\n');
    await expectLater(SmartRuleBundle.androidRules(root.path, '3.0.0'),
        throwsFormatException);
  });

  test('application policies precede manual exceptions in both modes', () {
    for (final mode in [ProxyMode.rule, ProxyMode.global]) {
      final config = ClashConfigGenerator.generateConfig(
        'proxies: [{name: Test, type: http, server: 127.0.0.1, port: 8080}]',
        AppSettings(
            proxyMode: mode,
            forceProxySites: ['proxy.example'],
            forceDirectSites: ['direct.example']),
        extraRulesBeforeDirect: const [
          'PROCESS-NAME,com.example.domestic,DIRECT',
          'PROCESS-NAME,com.example.foreign,PROXY',
        ],
      );
      final directApp =
          config.indexOf('PROCESS-NAME,com.example.domestic,DIRECT');
      final proxyApp = config.indexOf('PROCESS-NAME,com.example.foreign,PROXY');
      for (final manual in [
        'DOMAIN-SUFFIX,proxy.example,PROXY',
        'DOMAIN-SUFFIX,direct.example,DIRECT'
      ]) {
        expect(config.indexOf(manual), greaterThan(directApp));
        expect(config.indexOf(manual), greaterThan(proxyApp));
      }
      expect(directApp, isNonNegative);
      expect(proxyApp, isNonNegative);
    }
  });

  test('all platform files validate; desktop excludes application downloads',
      () async {
    final text = File('${assets.path}/manifest.json').readAsStringSync();
    final descriptor = SmartRuleBundle.parseVersionDescriptor(
        File('${assets.path}/version.json').readAsStringSync());
    expect(descriptor.acceptsManifest(text), isTrue);
    final android = SmartRuleBundle.parseManifest(text);
    final contents = {
      for (final name in android.files.keys)
        name: File('${assets.path}/$name').readAsStringSync(),
    };
    expect(SmartRuleBundle.providerContentsMatch(android, contents), isTrue);
    final directory = await Directory.systemTemp.createTemp('signed-rules-');
    addTearDown(() => directory.delete(recursive: true));
    expect(
        await SmartRuleBundle.installVerifiedProviderFiles(
            directory.path, android, contents),
        isTrue);
    final rules =
        await SmartRuleBundle.androidRules(directory.path, android.version);
    expect(rules, contains('PROCESS-NAME,com.tencent.mm,DIRECT'));
    expect(rules, contains('PROCESS-NAME,org.telegram.messenger,PROXY'));
    expect(rules.any((rule) => rule.contains('com.android.chrome')), isFalse);
    final config = ClashConfigGenerator.generateConfig(
      'proxies: [{name: Test, type: http, server: 127.0.0.1, port: 8080}]',
      AppSettings(forceProxySites: ['manual.example']),
      extraRulesBeforeDirect: rules,
    );
    final manual = config.indexOf('DOMAIN-SUFFIX,manual.example,PROXY');
    final directApp = config.indexOf('PROCESS-NAME,com.tencent.mm,DIRECT');
    final proxyApp =
        config.indexOf('PROCESS-NAME,org.telegram.messenger,PROXY');
    final gfw = config.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY');
    expect(manual, isNonNegative);
    expect(directApp, isNonNegative);
    expect(directApp, lessThan(manual));
    expect(proxyApp, isNonNegative);
    expect(proxyApp, lessThan(manual));
    expect(directApp, lessThan(gfw));
    expect(proxyApp, lessThan(gfw));
    final desktop = SmartRuleBundle.parseManifest(text,
        expectedFileNames: AppConstants.smartRuleProviderFiles.values.toSet());
    expect(
        desktop.files.keys.any(SmartRuleBundle.androidFiles.contains), isFalse);
    final tampered = Map<String, String>.of(contents)
      ..['direct_apps.yaml'] = 'payload:\n  - com.android.chrome\n';
    expect(SmartRuleBundle.providerContentsMatch(android, tampered), isFalse);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:yaml/yaml.dart';

typedef RuntimeGenerator = String Function(String, AppSettings,
    {String? preferredNodeName});
typedef AsyncRuntimeGenerator = Future<String> Function(String, AppSettings,
    {String? preferredNodeName});

/// The same disk-backed compatibility contract runs through all platform shells.
void registerRuntimeCompatibilityTests({
  required Future<SubscriptionServiceBase> Function(String) openSubscription,
  required void Function() resetSubscription,
  required RuntimeGenerator generate,
  required AsyncRuntimeGenerator generateAsync,
}) {
  for (final legacyMode in ['tunMode', 'enableSystemProxy']) {
    for (final background in [false, true]) {
      test(
          'legacy $legacyMode data survives runtime generation and reload (background=$background)',
          () async {
        final directory =
            await Directory.systemTemp.createTemp('ssrvpn-legacy-');
        addTearDown(() async {
          resetSubscription();
          await directory.delete(recursive: true);
        });
        resetSubscription();
        final link = 'hysteria2://fixture%3Acredential@node.example.test:443/'
            '?sni=tls.example.test&insecure=1&pinSHA256=${'a' * 64}'
            '&obfs=salamander&obfs-password=fixture-obfs#旧节点私家车';
        final padding = background
            ? '# ${'x' * ClashConfigGenerator.isolateThreshold}\n'
            : '';
        final yaml =
            padding + SubscriptionParser.parseSubscriptionContent(link)!;
        final sources = jsonEncode([
          {
            'id': 'old-source',
            'name': '旧节点',
            'url': link,
            'enabled': true,
            'autoUpdate': false,
            'lastUpdate': '2025-01-01T00:00:00Z',
          }
        ]);
        final oldSettings = jsonEncode({
          legacyMode: legacyMode == 'tunMode',
          'proxyPort': 17890,
          'socksPort': 17891,
          'apiPort': 19090,
          'lastSelectedNode': '旧节点私家车',
          'proxyMode': 'global',
          'forceProxySites': ['proxy.example.test'],
          'forceDirectSites': ['direct.example.test'],
        });
        final originals = {
          'subscriptions.json': sources,
          'subscription_cache.yaml': yaml,
          'settings.json': oldSettings,
        };
        for (final entry in originals.entries) {
          await File('${directory.path}/${entry.key}')
              .writeAsString(entry.value);
        }
        final service = await openSubscription(directory.path);
        final settings = AppSettings.fromJson(
            jsonDecode(oldSettings) as Map<String, dynamic>);
        expect(settings.enableTun, isTrue);
        expect(settings.lastSelectedNodeName, '旧节点私家车');
        final settingsBefore = jsonEncode(settings.toJson());
        final nodeBefore = jsonEncode(service.allNodes.single.toJson());
        final expectedProxy = (loadYaml(yaml)['proxies'] as List).single as Map;
        final revisionBefore = service.revision;
        var notifications = 0;
        service.addListener(() => notifications++);

        for (final tun in [false, true]) {
          // A collision-adjusted runtime copy must not become persisted settings.
          final runtimeSettings = settings.copyWith(
              enableTun: tun,
              proxyPort: 27890,
              socksPort: 27891,
              apiPort: 29090);
          final before = jsonEncode(runtimeSettings.toJson());
          final sync = generate(service.rawYaml!, runtimeSettings,
              preferredNodeName: '旧节点私家车');
          final async = await generateAsync(service.rawYaml!, runtimeSettings,
              preferredNodeName: '旧节点私家车');
          expect(async, sync);
          expect(jsonEncode(runtimeSettings.toJson()), before);
          final runtime = loadYaml(sync) as Map;
          final proxy = (runtime['proxies'] as List).single as Map;
          for (final entry in expectedProxy.entries) {
            expect(proxy[entry.key], entry.value,
                reason: '${entry.key} retained');
          }
          expect(runtime['mixed-port'], 27890);
          expect(runtime['external-controller'], '127.0.0.1:29090');
          expect(runtime['ipv6'], isTrue);
          expect(runtime['rules'],
              contains('DOMAIN-SUFFIX,proxy.example.test,PROXY'));
          expect(runtime['rules'],
              contains('DOMAIN-SUFFIX,direct.example.test,DIRECT'));
        }
        expect(service.subscriptions.single.url, link);
        expect(service.rawYaml, yaml);
        expect(jsonEncode(service.allNodes.single.toJson()), nodeBefore);
        expect(jsonEncode(settings.toJson()), settingsBefore);
        expect(service.revision, revisionBefore);
        expect(notifications, 0);
        for (final entry in originals.entries) {
          expect(await File('${directory.path}/${entry.key}').readAsString(),
              entry.value,
              reason: '${entry.key} must remain byte-identical');
        }
        resetSubscription();
        final reloaded = await openSubscription(directory.path);
        expect(reloaded.subscriptions.single.url, link);
        expect(reloaded.rawYaml, yaml);
        expect(jsonEncode(reloaded.allNodes.single.toJson()), nodeBefore);
      });
    }
  }
}

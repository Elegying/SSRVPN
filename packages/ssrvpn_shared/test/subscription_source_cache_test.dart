import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/controllers/subscription_screen_controller.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/services/subscription_node_codec.dart';
import 'package:ssrvpn_shared/services/subscription_source_cache.dart';
import 'package:ssrvpn_shared/utils/bounded_yaml.dart';

void main() {
  test('cache ownership cannot amplify bounded input into unlimited nodes', () {
    final ids = [for (var i = 0; i < 10; i++) 'source-$i'];
    final yaml = jsonEncode({
      'proxies': [
        for (var i = 0; i < 1001; i++)
          {
            'name': 'Node $i',
            'type': 'socks5',
            'server': 'a.invalid',
            'port': 443,
            SubscriptionParser.proxySourceIdsKey: ids
          },
      ],
    });
    expect(
      () =>
          SubscriptionSourceCache.extract(yaml, {for (final id in ids) id: id}),
      throwsA(isA<YamlResourceLimitException>()),
    );
  });

  late Directory directory;
  late _DiskService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ssrvpn-source-cache-');
    service = _DiskService();
    await service.init(directory.path);
  });
  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  Future<Subscription> addFeed(String name, String host, String yaml) async {
    final url = 'https://$host.invalid/sub';
    service.responses[url] = yaml;
    return service.addSubscription(name, url);
  }

  Future<void> reload() async {
    service.dispose();
    service = _DiskService();
    await service.init(directory.path);
  }

  test('offline deletion survives source rename, node edit and restart',
      () async {
    final first = await addFeed('Same feed', 'a', _yaml('Same node', 'a'));
    final second = await addFeed('Same feed', 'b', _yaml('Same node', 'b'));
    await service.refreshAllSubscriptions();
    await service.updateNode('Same node (2)', {
      'name': 'Edited survivor',
      'type': 'socks5',
      'server': 'edited.invalid',
      'port': 443,
    });
    await service.updateSubscription(Subscription(
      id: second.id,
      name: 'Renamed feed',
      url: second.url,
      lastUpdate: second.lastUpdate,
    ));
    await reload();
    await service.removeSubscription(first.id);
    expect(service.fetchCalls, 0);
    expect(service.allNodes.single.name, 'Edited survivor');
    expect(service.allNodes.single.server, 'edited.invalid');
    expect(service.allNodes.single.group, 'Renamed feed');
    await reload();
    expect(service.subscriptions.single.id, second.id);
    expect(service.allNodes.single.name, 'Edited survivor');
  });

  test('deduplicated nodes retain the surviving source after offline deletion',
      () async {
    final first = await addFeed('A', 'a', _yaml('Shared', 'shared'));
    final second = await addFeed('B', 'b', _yaml('Shared', 'shared'));
    await service.refreshAllSubscriptions();
    expect(service.allNodes, hasLength(1));
    await reload();
    await service.removeSubscription(first.id);
    expect(service.fetchCalls, 0);
    expect(service.allNodes.single.name, 'Shared');
    expect(service.allNodes.single.group, 'B');
    await reload();
    expect(service.allNodes.single.name, 'Shared');
    await service.removeSubscription(second.id);
    await reload();
    expect(service.subscriptions, isEmpty);
    expect(service.allNodes, isEmpty);
  });

  test('partial refresh commits good sources and retains bad source snapshots',
      () async {
    final first = await addFeed('A', 'a', _yaml('Old A', 'a'));
    final second = await addFeed('B', 'b', _yaml('Old B', 'b'));
    await service.refreshAllSubscriptions();
    final lastUpdate = second.lastUpdate;
    service.responses[first.url] = _yaml('New A', 'new-a');
    service.responses[second.url] = const SocketException('offline');
    final result = await service.refreshAllSubscriptionsDetailed();
    expect(result.isPartialSuccess, isTrue);
    expect(result.successfulSubscriptionIds, [first.id]);
    expect(second.lastUpdate, lastUpdate);
    expect(service.allNodes.map((node) => node.name), ['New A', 'Old B']);
    await reload();
    expect(service.allNodes.map((node) => node.name), ['New A', 'Old B']);
  });

  test(
      'local import is immediate even when an old remote source never responds',
      () async {
    final remote = await addFeed('A', 'a', _yaml('Old A', 'a'));
    await service.refreshAllSubscriptions();
    service.responses[remote.url] = Completer<String?>().future;
    final calls = service.fetchCalls;
    final controller =
        SubscriptionScreenController(subscriptionService: _port(service));
    final result = await controller
        .addSubscription(
          'socks5://127.0.0.1:18080#Local rescue',
        )
        .timeout(const Duration(seconds: 1));
    expect(result.isSuccess, isTrue);
    expect(service.fetchCalls, calls);
    expect(
        service.allNodes.map((node) => node.name), ['Old A', 'Local rescue']);
    await reload();
    expect(
        service.allNodes.map((node) => node.name), ['Old A', 'Local rescue']);
  });

  test(
      'malformed source cannot erase its last good nodes during partial refresh',
      () async {
    final first = await addFeed('A', 'a', _yaml('Old A', 'a'));
    final second = await addFeed('B', 'b', _yaml('Old B', 'b'));
    await service.refreshAllSubscriptions();
    service.responses[first.url] = _yaml('New A', 'a');
    service.responses[second.url] = 'proxies: [{name: invalid, port: 0}]';
    final result = await service.refreshAllSubscriptionsDetailed();
    expect(result.isPartialSuccess, isTrue);
    expect(service.allNodes.map((node) => node.name), ['New A', 'Old B']);
  });

  test('failed metadata commit restores source ownership on disk and in memory',
      () async {
    final first = await addFeed('A', 'a', _yaml('Old A', 'a'));
    final second = await addFeed('B', 'b', _yaml('Old B', 'b'));
    await service.refreshAllSubscriptions();
    final previousYaml = service.rawYaml;
    service.failMetadata = true;
    await expectLater(service.removeSubscription(first.id),
        throwsA(isA<FileSystemException>()));
    expect(service.rawYaml, previousYaml);
    expect(service.subscriptions, hasLength(2));
    await reload();
    expect(service.rawYaml, previousYaml);
    expect(service.subscriptions, hasLength(2));
    await service.removeSubscription(second.id);
    expect(service.allNodes.single.name, 'Old A');
  });

  test('legacy local nodes sharing one display group retain distinct owners',
      () async {
    final first =
        await service.addSubscription('A', 'socks5://a.invalid:443#Same');
    await service.addSubscription('B', 'socks5://b.invalid:443#Same');
    final legacy = jsonDecode(jsonEncode(BoundedYaml.load(service.rawYaml!)))
        as Map<String, dynamic>;
    for (final proxy in legacy['proxies'] as List) {
      (proxy as Map).remove(SubscriptionParser.proxySourceIdsKey);
      proxy.remove(SubscriptionParser.proxyOriginalNameKey);
    }
    await service.setRawYaml(SubscriptionNodeCodec.encodeConfig(legacy));
    await reload();
    await service.removeSubscription(first.id);
    expect(service.fetchCalls, 0);
    expect(service.allNodes.single.name, 'Same (2)');
    expect(service.allNodes.single.server, 'b.invalid');
  });

  test('provider metadata cannot claim another local source owner', () async {
    final first = await addFeed('A', 'a', _yaml('A', 'a'));
    final second = await addFeed('B', 'b', '''
proxies:
  - {name: B, type: socks5, server: b.invalid, port: 443, ssrvpn-subscription-ids: ["${first.id}"], ssrvpn-original-name: forged}
''');
    await service.refreshAllSubscriptions();
    await service.removeSubscription(first.id);
    expect(service.subscriptions.single.id, second.id);
    expect(service.allNodes.single.name, 'B');
  });

  test('ambiguous legacy labels survive deletion until a complete refresh',
      () async {
    final first =
        await service.addSubscription('Legacy A', 'https://a.invalid/sub');
    await service.addSubscription('Legacy B', 'https://b.invalid/sub');
    await service.setRawYaml('''
proxies:
  - {name: A, type: socks5, server: a.invalid, port: 443, ssrvpn-subscription: Legacy A}
  - {name: B, type: socks5, server: b.invalid, port: 443, ssrvpn-subscription: Legacy B}
''');
    await reload();
    await service.removeSubscription(first.id);
    expect(service.fetchCalls, 0);
    expect(service.allNodes.map((node) => node.name), ['A', 'B']);
    expect(service.allNodes.map((node) => node.group).toSet(), {'历史缓存'});
    await reload();
    expect(service.allNodes.map((node) => node.name), ['A', 'B']);
    service.responses['https://b.invalid/sub'] = _yaml('B', 'b');
    await service.refreshAllSubscriptions();
    expect(service.allNodes.single.name, 'B');
    expect(service.allNodes.single.group, 'Legacy B');
  });

  test('legacy deduplication never treats the first label as exclusive owner',
      () async {
    final first = await addFeed('A', 'a', _yaml('Shared', 'shared'));
    await addFeed('B', 'b', _yaml('Shared', 'shared'));
    await service.refreshAllSubscriptions();
    final legacy = jsonDecode(jsonEncode(BoundedYaml.load(service.rawYaml!)))
        as Map<String, dynamic>;
    for (final proxy in legacy['proxies'] as List) {
      (proxy as Map).remove(SubscriptionParser.proxySourceIdsKey);
      proxy.remove(SubscriptionParser.proxyOriginalNameKey);
    }
    await service.setRawYaml(SubscriptionNodeCodec.encodeConfig(legacy));
    await reload();
    await service.removeSubscription(first.id);
    expect(service.fetchCalls, 0);
    expect(service.allNodes.single.name, 'Shared');
    expect(service.allNodes.single.group, '历史缓存');
    await reload();
    expect(service.allNodes.single.name, 'Shared');
    service.responses['https://b.invalid/sub'] = _yaml('Shared', 'shared');
    await service.refreshAllSubscriptions();
    expect(service.allNodes.single.group, 'B');
  });

  test('rename updates display metadata without changing runtime or latency',
      () async {
    final source = await addFeed('Before', 'a', _yaml('A', 'a'));
    await service.refreshAllSubscriptions();
    final revision = service.revision;
    final displayRevision = service.displayRevision;
    final proxies = ClashConfigGenerator.buildProxiesText(service.rawYaml!);
    final testedAt = DateTime(2026, 9, 5);
    service.allNodes.single
      ..latency = 81
      ..lastLatencyTest = testedAt
      ..isOnline = true;
    final calls = service.fetchCalls;
    final result = await SubscriptionScreenController.fromService(service)
        .editSubscription(source, 'After', source.url);
    expect(result.status, SubscriptionEditStatus.saved);
    expect(service.fetchCalls, calls);
    expect(service.revision, revision);
    expect(service.displayRevision, greaterThan(displayRevision));
    expect(ClashConfigGenerator.buildProxiesText(service.rawYaml!), proxies);
    expect(service.allNodes.single.group, 'After');
    expect(service.allNodes.single.latency, 81);
    expect(service.allNodes.single.lastLatencyTest, testedAt);
    expect(service.allNodes.single.isOnline, isTrue);
  });

  test('editing one source preserves manual edits in every other source',
      () async {
    await addFeed('A', 'a', _yaml('A', 'a'));
    final second = await addFeed('B', 'b', _yaml('B', 'b'));
    await service.refreshAllSubscriptions();
    await service.updateNode('A', {
      'name': 'Manual A',
      'type': 'socks5',
      'server': 'manual.invalid',
      'port': 444,
    });
    final controller = SubscriptionScreenController.fromService(service);
    service.requestedUrls.clear();
    expect(
        (await controller.editSubscription(second, 'Renamed B', second.url))
            .status,
        SubscriptionEditStatus.saved);
    expect(service.requestedUrls, isEmpty);
    expect(service.allNodes.first.name, 'Manual A');
    final updated = service.subscriptions.last;
    const newUrl = 'https://new-b.invalid/sub';
    service.responses[newUrl] = _yaml('New B', 'new-b');
    expect(
        (await controller.editSubscription(updated, updated.name, newUrl))
            .status,
        SubscriptionEditStatus.saved);
    expect(service.requestedUrls, [newUrl]);
    expect(service.allNodes.map((node) => node.name), ['Manual A', 'New B']);
    expect(service.allNodes.first.server, 'manual.invalid');
    expect(service.subscriptions.last.lastUpdate, isNotNull);
    await reload();
    expect(service.allNodes.map((node) => node.name), ['Manual A', 'New B']);
  });

  test('failed URL edit retains the old link, nodes and disk state', () async {
    final source = await addFeed('A', 'a', _yaml('Old A', 'a'));
    await service.refreshAllSubscriptions();
    final yaml = service.rawYaml;
    final revision = service.revision;
    final timestamp = source.lastUpdate;
    service.responses['https://bad.invalid/sub'] = 'proxies: []';
    final result = await SubscriptionScreenController.fromService(service)
        .editSubscription(source, 'Bad', 'https://bad.invalid/sub');
    expect(result.status, SubscriptionEditStatus.failed);
    expect(service.subscriptions.single.url, source.url);
    expect(service.subscriptions.single.name, source.name);
    expect(service.subscriptions.single.lastUpdate, timestamp);
    expect(service.rawYaml, yaml);
    expect(service.revision, revision);
    await reload();
    expect(service.subscriptions.single.url, source.url);
    expect(service.rawYaml, yaml);
  });

  test('new remote imports and retries fetch only the requested source',
      () async {
    final old = await addFeed('A', 'a', _yaml('A', 'a'));
    await service.refreshAllSubscriptions();
    service.responses[old.url] = Completer<String?>().future;
    const newUrl = 'https://new.invalid/sub';
    service.responses[newUrl] = _yaml('New', 'new');
    service.requestedUrls.clear();
    final controller = SubscriptionScreenController.fromService(service);
    final imported = await controller
        .addSubscription(newUrl)
        .timeout(const Duration(seconds: 1));
    expect(imported.isSuccess, isTrue);
    expect(service.requestedUrls, [newUrl]);
    expect(service.allNodes.map((node) => node.name), ['A', 'New']);
    service.responses[newUrl] = const SocketException('offline');
    expect(
        (await controller.addSubscription(newUrl, retryExisting: true))
            .isSuccess,
        isFalse);
    expect(service.allNodes.map((node) => node.name), ['A', 'New']);
    service.responses[newUrl] = _yaml('Retried', 'new');
    expect(
        (await controller.addSubscription(newUrl, retryExisting: true))
            .isSuccess,
        isTrue);
    expect(service.requestedUrls, [newUrl, newUrl, newUrl]);
    expect(service.subscriptions, hasLength(2));
    expect(service.allNodes.map((node) => node.name), ['A', 'Retried']);
  });

  for (final url in [
    'socks5://bad.invalid:70000#Invalid',
    'trojan://password@bad.invalid:70000#Invalid',
    'socks5://bad.invalid:443#剩余流量',
  ]) {
    test('unrunnable import cannot hide behind existing nodes: $url', () async {
      await service.addSubscription(
          'Valid', 'socks5://valid.invalid:443#Valid');
      final previousYaml = service.rawYaml;
      final result = await SubscriptionScreenController.fromService(service)
          .addSubscription(url);
      expect(result.isSuccess, isFalse);
      expect(service.subscriptions, hasLength(1));
      expect(service.rawYaml, previousYaml);
      await expectLater(
          service.addSubscription('Invalid', url), throwsException);
      await reload();
      expect(service.subscriptions, hasLength(1));
      expect(service.allNodes.single.name, 'Valid');
    });
  }

  test('retrying a local import never fetches an unrelated remote source',
      () async {
    await addFeed('Unavailable', 'bad', _yaml('Old', 'old'));
    const url = 'socks5://rescue.invalid:443#Rescue';
    final controller = SubscriptionScreenController.fromService(service);
    expect((await controller.addSubscription(url)).isSuccess, isTrue);
    expect(
        (await controller.addSubscription(url, retryExisting: true)).isSuccess,
        isTrue);
    expect(service.fetchCalls, 0);
    expect(service.subscriptions, hasLength(2));
    expect(service.allNodes.single.name, 'Rescue');
  });
}

String _yaml(String name, String host) => '''
proxies:
  - {name: "$name", type: socks5, server: $host.invalid, port: 443}
''';

class _DiskService extends SubscriptionServiceBase {
  final responses = <String, Object>{};
  int fetchCalls = 0;
  final requestedUrls = <String>[];
  bool failMetadata = false;
  @override
  Future<String?> fetchSubscription(
    String url, {
    int maxRetries = 3,
    SubscriptionRefreshControl? control,
  }) async {
    fetchCalls++;
    requestedUrls.add(url);
    final response = responses[url];
    if (response is Future<String?>) return response;
    if (response is String) return response;
    throw response ?? const SocketException('offline');
  }

  @override
  Future<void> saveToDisk() async {
    if (failMetadata) throw const FileSystemException('metadata commit failed');
    await super.saveToDisk();
  }
}

SubscriptionScreenServicePort _port(SubscriptionServiceBase service) =>
    CallbackSubscriptionScreenService(
      subscriptionsOf: () => service.subscriptions,
      allNodesOf: () => service.allNodes,
      allGroupsOf: () => service.allGroups,
      isSingleNodeLinkOf: service.isSingleNodeLink,
      defaultSubscriptionNameOf: service.defaultSubscriptionName,
      addSubscriptionWith: service.addSubscription,
      refreshSubscriptionWith: service.refreshSubscription,
      refreshAllSubscriptionsDetailedWith:
          service.refreshAllSubscriptionsDetailed,
      removeSubscriptionWith: service.removeSubscription,
      updateSubscriptionWith: service.updateSubscription,
    );

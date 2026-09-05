import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/services/subscription_source_cache.dart';
import 'package:ssrvpn_shared/services/subscription_yaml_merger.dart';
import 'package:ssrvpn_shared/utils/proxy_dependency_policy.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> _proxy(String name, String host, {String? via}) => {
      'name': name,
      'type': 'socks5',
      'server': '$host.invalid',
      'port': 443,
      if (via != null) 'dialer-proxy': via,
    };
String _yaml(List<Map<String, dynamic>> nodes) =>
    'proxies:\n${nodes.map((node) => '  - ${jsonEncode(node)}\n').join()}';
String _chain(String entry) => _yaml([
      _proxy('Entry', entry),
      _proxy('Exit', 'exit', via: 'Entry'),
    ]);
List<Map<String, dynamic>> _proxies(String yaml) =>
    (jsonDecode(jsonEncode(loadYaml(yaml)))['proxies'] as List)
        .cast<Map<String, dynamic>>();
String _merge(List<String> sources, {String? previous}) =>
    SubscriptionYamlMerger.mergeYamlConfigs(sources,
        sourceNames: ['A', 'B'].take(sources.length).toList(),
        sourceIds: ['a', 'b'].take(sources.length).toList(),
        previousYaml: previous);
Map<String, dynamic> _target(
        List<Map<String, dynamic>> nodes, Map<String, dynamic> exit) =>
    nodes.singleWhere((node) => node['name'] == exit['dialer-proxy']);

void main() {
  test('colliding entries keep each source on its own chain', () {
    final nodes = _proxies(_merge([
      _yaml([_proxy('Entry', 'a')]),
      _chain('b'),
    ]));
    final exit = nodes.singleWhere((node) => node['name'] == 'Exit');
    expect(_target(nodes, exit)['server'], 'b.invalid');
    expect(exit['dialer-proxy'], 'Entry (2)');
  });

  test('deduplication includes upstream identity and preserves shared graphs',
      () {
    final distinct = _proxies(_merge([_chain('a'), _chain('b')]));
    expect(distinct, hasLength(4));
    final exits = distinct.where((node) => node['server'] == 'exit.invalid');
    expect(exits.map((node) => _target(distinct, node)['server']),
        ['a.invalid', 'b.invalid']);
    final shared = _proxies(_merge([_chain('a'), _chain('a')]));
    expect(shared, hasLength(2));
    expect(shared.last[SubscriptionParser.proxySourceIdsKey], ['a', 'b']);
    expect(_target(shared, shared.last)['server'], 'a.invalid');
  });

  test('cache extraction and refresh retain source references and stable names',
      () {
    final merged = _merge([_chain('a'), _chain('b')]);
    final sources =
        SubscriptionSourceCache.extract(merged, {'a': 'A', 'b': 'B'});
    for (final id in ['a', 'b']) {
      final nodes = _proxies(sources[id]!);
      expect(nodes.last['dialer-proxy'], 'Entry');
      expect(_target(nodes, nodes.last)['server'], '$id.invalid');
    }
    final refreshed =
        _proxies(_merge([_chain('a-new'), sources['b']!], previous: merged));
    final b = refreshed.singleWhere((node) => node['server'] == 'b.invalid');
    expect(b['name'], 'Entry (2)');
    final bExit = refreshed.singleWhere((node) => node['name'] == 'Exit (2)');
    expect(_target(refreshed, bExit)['server'], 'b.invalid');
    final sharedSources = SubscriptionSourceCache.extract(
        _merge([_chain('a'), _chain('a')]), {'a': 'A', 'b': 'B'});
    expect(_proxies(sharedSources['b']!).last['dialer-proxy'], 'Entry');
  });

  test('canonical and built-in references survive runtime generation', () {
    final yaml = _yaml([
      _proxy('Entry', 'a', via: 'DIRECT'),
      _proxy('Exit', 'exit', via: ' E\tntry '),
    ]);
    final merged = _merge([yaml]);
    final nodes =
        _proxies('proxies:\n${ClashConfigGenerator.buildProxiesText(merged)}');
    expect(nodes.first['dialer-proxy'], 'DIRECT');
    expect(nodes.last['dialer-proxy'], 'Entry');
  });

  for (final invalid in <String, List<Map<String, dynamic>>>{
    'missing': [_proxy('Exit', 'exit', via: 'Missing')],
    'discarded group': [_proxy('Exit', 'exit', via: 'PROXY')],
    'non-string': [
      {..._proxy('Exit', 'exit'), 'dialer-proxy': 42}
    ],
    'blank reference': [_proxy('Exit', 'exit', via: ' \t ')],
    'self cycle': [_proxy('Exit', 'exit', via: 'Exit')],
    'cycle': [
      _proxy('Entry', 'a', via: 'Exit'),
      _proxy('Exit', 'exit', via: 'Entry')
    ],
    'ambiguous': [
      _proxy('Entry', 'a'),
      _proxy('Entry', 'b'),
      _proxy('Exit', 'exit', via: 'Entry')
    ],
  }.entries) {
    test('${invalid.key} fails instead of silently choosing a different route',
        () {
      final yaml = _yaml(invalid.value);
      expect(() => _merge([yaml]), throwsFormatException);
      expect(() => ClashConfigGenerator.buildProxiesText(yaml),
          throwsFormatException);
    });
  }

  test('long valid and cyclic chains do not recurse on the call stack', () {
    final nodes = [
      for (var i = 0; i < 4000; i++)
        _proxy('Node$i', 'node$i', via: i == 3999 ? null : 'Node${i + 1}')
    ];
    expect(ProxyDependencyPolicy.resolve(nodes), hasLength(4000));
    nodes.last['dialer-proxy'] = 'Node0';
    expect(() => ProxyDependencyPolicy.resolve(nodes), throwsFormatException);
  });

  late Directory directory;
  late _Service service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ssrvpn-chain-');
    service = _Service();
    await service.init(directory.path);
  });
  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  test('editing an entry rewrites dependent proxies and survives restart',
      () async {
    await service.setRawYaml(_chain('a'));
    await service.updateNode(
        'Entry', {...service.allNodes.first.extra, 'name': 'Renamed'});
    expect(_proxies(service.rawYaml!).last['dialer-proxy'], 'Renamed');
    final restarted = _Service();
    addTearDown(restarted.dispose);
    await restarted.init(directory.path);
    expect(_proxies(restarted.rawYaml!).last['dialer-proxy'], 'Renamed');
    expect(
        ClashConfigGenerator.buildProxiesText(restarted.rawYaml!), isNotEmpty);
  });

  test('invalid edit and replacement preserve the committed disk cache',
      () async {
    await service.setRawYaml(_chain('a'));
    final previous = service.rawYaml;
    await expectLater(
        service.updateNode('Entry', {
          ...service.allNodes.first.extra,
          'dialer-proxy': 'Exit',
        }),
        throwsFormatException);
    await expectLater(
        service.setRawYaml(jsonEncode({
          'proxies': [
            _proxy('Exit', 'exit', via: 'Missing'),
          ]
        })),
        throwsFormatException);
    expect(service.rawYaml, previous);
    expect(
        await File('${directory.path}/subscription_cache.yaml').readAsString(),
        previous);
  });

  test(
      'an invalid refreshed chain preserves its source while other sources update',
      () async {
    final a = await service.addSubscription('A', 'https://a.invalid/sub');
    final b = await service.addSubscription('B', 'https://b.invalid/sub');
    service.responses.addAll({a.url: _chain('a'), b.url: _chain('b')});
    await service.refreshAllSubscriptionsDetailed();
    service.responses[a.url] = _yaml([_proxy('Exit', 'exit', via: 'Missing')]);
    service.responses[b.url] = _chain('b-new');
    final result = await service.refreshAllSubscriptionsDetailed();
    expect(result.isPartialSuccess, isTrue);
    final nodes = _proxies(service.rawYaml!);
    final exits = nodes.where((node) => node['server'] == 'exit.invalid');
    expect(exits.map((node) => _target(nodes, node)['server']),
        ['a.invalid', 'b-new.invalid']);
    expect(
        await File('${directory.path}/subscription_cache.yaml').readAsString(),
        service.rawYaml);
  });

  test('offline source removal keeps the surviving chain reachable', () async {
    final a = await service.addSubscription('A', 'https://a.invalid/sub');
    final b = await service.addSubscription('B', 'https://b.invalid/sub');
    service.responses.addAll({a.url: _chain('a'), b.url: _chain('b')});
    await service.refreshAllSubscriptionsDetailed();
    service.responses[a.url] = _chain('a-new');
    service.responses.remove(b.url);
    final partial = await service.refreshAllSubscriptionsDetailed();
    expect(partial.isPartialSuccess, isTrue);
    await service.removeSubscription(a.id);
    final nodes = _proxies(service.rawYaml!);
    expect(nodes, hasLength(2));
    expect(_target(nodes, nodes.last)['server'], 'b.invalid');
    expect(nodes.last['name'], 'Exit (2)');
  });
}

class _Service extends SubscriptionServiceBase {
  final responses = <String, String>{};
  @override
  Future<String?> fetchSubscription(String url,
      {int maxRetries = 3, SubscriptionRefreshControl? control}) async {
    return responses[url] ?? (throw const SocketException('synthetic offline'));
  }
}

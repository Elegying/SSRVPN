import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/controllers/node_country_controller.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/node_country_lookup.dart';

const _answer = NodeCountryResolution(ip: '8.8.8.8', countryCode: 'US');

ProxyNode _node({
  String name = '日本测试线路',
  String server = 'relay.example.invalid',
  int port = 443,
  String type = 'hysteria2',
}) =>
    ProxyNode(
      name: name,
      type: type,
      server: server,
      port: port,
      extra: {
        'password': 'fixture-password-only',
        'uuid': 'fixture-uuid-only',
        'subscriptionUrl': 'https://fixture.invalid/private-subscription',
      },
    );

Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: reason);
}

class _Request {
  final result = Completer<NodeCountryResolution?>();
}

class _Lookup extends NodeCountryLookup {
  _Lookup(this.requests, int port, {this.immediateReply = false})
      : super(
          proxyPort: port,
          client: MockClient((_) => throw StateError('Unexpected network use')),
        );

  final List<_Request> requests;
  final bool immediateReply;
  bool closed = false;

  @override
  Future<NodeCountryResolution?> lookup() {
    final request = _Request();
    requests.add(request);
    if (immediateReply) request.result.complete(_answer);
    return request.result.future;
  }

  @override
  void close() {
    closed = true;
    // Deliberately allow late completion to exercise the controller's epoch guard.
    super.close();
  }
}

class _Harness {
  _Harness(this.directory, this.nodes, Duration delay, bool immediateReply) {
    controller = NodeCountryController(
      stableDelay: delay,
      lookupFactory: (port) {
        ports.add(port);
        final lookup = _Lookup(requests, port, immediateReply: immediateReply);
        lookups.add(lookup);
        return lookup;
      },
    );
  }

  final Directory directory;
  List<ProxyNode> nodes;
  late final NodeCountryController controller;
  final requests = <_Request>[];
  final lookups = <_Lookup>[];
  final ports = <int>[];
  int selectedIndex = 0;
  String? coreSelection;
  bool connected = false;
  bool busy = false;
  bool current = true;
  Object session = Object();
  int port = 7890;
  bool disposed = false;

  static Future<_Harness> create(
    List<ProxyNode> nodes, {
    Duration delay = const Duration(milliseconds: 5),
    Directory? directory,
    bool immediateReply = false,
  }) async {
    final ownsDirectory = directory == null;
    final harness = _Harness(
      directory ?? await Directory.systemTemp.createTemp('node-countries-'),
      nodes,
      delay,
      immediateReply,
    );
    addTearDown(() async {
      await harness.close();
      if (ownsDirectory && await harness.directory.exists()) {
        await harness.directory.delete(recursive: true);
      }
    });
    final loaded = Completer<void>();
    void listener() {
      if (!loaded.isCompleted) loaded.complete();
    }

    harness.controller.addListener(listener);
    harness.update();
    await loaded.future.timeout(const Duration(seconds: 3));
    harness.controller.removeListener(listener);
    return harness;
  }

  void update() => controller.update(
        nodes: nodes,
        selectedNode: nodes.isEmpty ? null : nodes[selectedIndex],
        currentSelectedProxyName: () async =>
            coreSelection ?? nodes[selectedIndex].name,
        connected: connected,
        busy: busy,
        session: session,
        proxyPort: port,
        cacheDirectory: directory.path,
        isConnectionCurrent: () => current,
      );

  void connect() {
    connected = true;
    update();
  }

  Future<void> close() async {
    if (disposed) return;
    disposed = true;
    controller.dispose();
    for (final request in requests) {
      if (!request.result.isCompleted) request.result.complete();
    }
    await controller.flush();
  }
}

void main() {
  test('waits for a stable connection before enriching supplied hints',
      () async {
    final node = _node();
    final harness = await _Harness.create(
      [node],
      delay: const Duration(milliseconds: 60),
    );
    expect(harness.controller.countryFor(node), 'JP');
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(harness.requests, isEmpty);
    harness.connect();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(harness.requests, isEmpty);
    await _until(() => harness.requests.length == 1);
    expect(harness.ports, [7890]);
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.controller.countryFor(node) == 'US');
  });

  test('latency work cancels the stability timer and active lookups', () async {
    final harness = await _Harness.create(
      [_node()],
      delay: const Duration(milliseconds: 20),
    );
    harness.connect();
    harness.busy = true;
    harness.update();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(harness.lookups, isEmpty);
    harness.busy = false;
    harness.update();
    await _until(() => harness.requests.length == 1);
    harness.busy = true;
    harness.update();
    expect(harness.lookups.single.closed, isTrue);
    harness.requests.single.result.complete(_answer);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(harness.controller.countryFor(harness.nodes.single), 'JP');
    harness.busy = false;
    harness.update();
    await _until(() => harness.requests.length == 2);
  });

  test('disconnect and stale connection predicates prevent lookups', () async {
    final harness = await _Harness.create([_node()]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.connected = false;
    harness.update();
    expect(harness.lookups.single.closed, isTrue);
    harness.requests.single.result.complete(_answer);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(harness.controller.countryFor(harness.nodes.single), 'JP');
    harness.current = false;
    harness.connected = true;
    harness.session = Object();
    harness.update();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(harness.requests, hasLength(1));
  });

  test(
      'only the connected node learns an exit; other relay ports stay independent',
      () async {
    final nodes = [_node(name: '日本 A'), _node(name: '日本 B', port: 8443)];
    final harness = await _Harness.create(nodes);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.controller.countryFor(nodes.first) == 'US');
    expect(harness.controller.countryFor(nodes.last), 'JP');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(harness.requests, hasLength(1));
    harness.selectedIndex = 1;
    harness.update();
    await _until(() => harness.requests.length == 2);
    harness.requests.last.result.complete(
        const NodeCountryResolution(ip: '1.1.1.1', countryCode: 'AU'));
    await _until(() => harness.controller.countryFor(nodes.last) == 'AU');
    expect(harness.controller.countryFor(nodes.first), 'US');
  });

  test(
      'selection changes cancel old exit observations even in the same session',
      () async {
    final nodes = [_node(name: '日本 A'), _node(name: '日本 B', port: 8443)];
    final harness = await _Harness.create(nodes);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.selectedIndex = 1;
    harness.update();
    expect(harness.lookups.first.closed, isTrue);
    harness.requests.first.result.complete(_answer);
    await _until(() => harness.requests.length == 2);
    expect(harness.controller.countryFor(nodes.first), 'JP');
    expect(harness.controller.countryFor(nodes.last), 'JP');
  });

  test('actual core selection must match before and after observing the exit',
      () async {
    final node = _node();
    final harness = await _Harness.create([node]);
    harness.coreSelection = 'different-runtime-node';
    harness.connect();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(harness.requests, isEmpty);
    harness.coreSelection = node.name;
    harness.update();
    await _until(() => harness.requests.length == 1);
    harness.coreSelection = 'different-runtime-node';
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.lookups.single.closed);
    expect(harness.controller.countryFor(node), 'JP');
  });

  test('legacy server-country cache is ignored and replaced with observed exit',
      () async {
    final dir = await Directory.systemTemp.createTemp('legacy-node-country-');
    addTearDown(() => dir.delete(recursive: true));
    final node = _node();
    await File('${dir.path}/${NodeCountryController.cacheFileName}')
        .writeAsString(jsonEncode({
      'version': 1,
      'countries': {NodeCountryController.endpointKey(node): 'CN'}
    }));
    final harness = await _Harness.create([node], directory: dir);
    expect(harness.controller.countryFor(node), 'JP');
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.controller.countryFor(node) == 'US');
    await harness.controller.flush();
    final saved = jsonDecode(
        await File('${dir.path}/${NodeCountryController.cacheFileName}')
            .readAsString()) as Map;
    expect(saved['version'], NodeCountryController.cacheVersion);
  });

  test('changing a dialer route invalidates the dependent exit cache',
      () async {
    final parent = _node(name: 'Transit');
    final child = _node(name: '日本出口', server: 'exit.invalid')
        .copyWith(extra: {..._node().extra, 'dialer-proxy': 'Transit'});
    final harness = await _Harness.create([parent, child]);
    harness.selectedIndex = 1;
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.controller.countryFor(child) == 'US');
    harness.nodes = [parent.copyWith(port: 8443), child];
    harness.update();
    expect(harness.controller.countryFor(child), 'JP');
    await _until(() => harness.requests.length == 2);
  });

  test('successful endpoint survives reconnect and a fresh controller restart',
      () async {
    final node = _node();
    final harness = await _Harness.create([node]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.controller.countryFor(node) == 'US');
    harness.connected = false;
    harness.update();
    harness.session = Object();
    harness.connect();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(harness.requests, hasLength(1));
    await harness.close();

    final restarted =
        await _Harness.create([node], directory: harness.directory);
    expect(restarted.controller.countryFor(node), 'US');
    restarted.connect();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(restarted.lookups, isEmpty);
  });

  test('rename reuses the endpoint while changed host or port requires lookup',
      () async {
    final node = _node();
    final harness = await _Harness.create([node]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.controller.countryFor(node) == 'US');
    final renamed = node.copyWith(name: '香港改名线路');
    harness.nodes = [renamed];
    harness.update();
    expect(harness.controller.countryFor(renamed), 'US');
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(harness.requests, hasLength(1));

    final moved = renamed.copyWith(server: 'moved.example.invalid', port: 8443);
    harness.nodes = [moved];
    harness.update();
    expect(harness.controller.countryFor(moved), 'HK');
    await _until(() => harness.requests.length == 2);
    harness.requests.last.result.complete(
      const NodeCountryResolution(ip: '1.1.1.1', countryCode: 'DE'),
    );
    await _until(() => harness.controller.countryFor(moved) == 'DE');
  });

  test('failed lookups retain hints and retry only in a later session',
      () async {
    final harness = await _Harness.create([_node()]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.completeError(StateError('Lookup failed'));
    await _until(() => harness.lookups.single.closed);
    expect(harness.controller.countryFor(harness.nodes.single), 'JP');
    harness.update();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(harness.requests, hasLength(1));
    harness.session = Object();
    harness.update();
    await _until(() => harness.requests.length == 2);
  });

  test('non-public answers never replace hints or enter the cache', () async {
    final harness = await _Harness.create([_node()]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete(
      const NodeCountryResolution(ip: '198.18.0.7', countryCode: 'US'),
    );
    await _until(() => harness.lookups.single.closed);
    expect(harness.controller.countryFor(harness.nodes.single), 'JP');
    await harness.controller.flush();
    final cache = jsonDecode(await File(
      '${harness.directory.path}/${NodeCountryController.cacheFileName}',
    ).readAsString()) as Map;
    expect(cache['countries'], isEmpty);
  });

  test('same intent reconnect retries a failed endpoint without losing hints',
      () async {
    final harness = await _Harness.create([_node()]);
    final intent = harness.session;
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete();
    await _until(() => harness.lookups.single.closed);
    harness.connected = false;
    harness.update();
    harness.connect();
    expect(harness.session, same(intent));
    expect(harness.controller.countryFor(harness.nodes.single), 'JP');
    await _until(() => harness.requests.length == 2);
    harness.requests.last.result.complete(_answer);
    await _until(
        () => harness.controller.countryFor(harness.nodes.single) == 'US');
  });

  test('latency pause alone does not retry an already failed endpoint',
      () async {
    final harness = await _Harness.create([_node()]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete();
    await _until(() => harness.lookups.single.closed);
    harness.busy = true;
    harness.update();
    harness.busy = false;
    harness.update();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(harness.requests, hasLength(1));
    expect(harness.controller.countryFor(harness.nodes.single), 'JP');
  });

  test('late results from an old session cannot overwrite the new session',
      () async {
    final harness = await _Harness.create([_node()]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.session = Object();
    harness.update();
    expect(harness.lookups.first.closed, isTrue);
    await _until(() => harness.requests.length == 2);
    harness.requests.last.result.complete(
      const NodeCountryResolution(ip: '1.1.1.1', countryCode: 'DE'),
    );
    await _until(
        () => harness.controller.countryFor(harness.nodes.single) == 'DE');
    harness.requests.first.result.complete(_answer);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(harness.controller.countryFor(harness.nodes.single), 'DE');
  });

  test('disk cache contains only hashed endpoint keys and country codes',
      () async {
    final node = _node(server: 'private-relay.example.invalid');
    final harness = await _Harness.create([node]);
    harness.connect();
    await _until(() => harness.requests.length == 1);
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.controller.countryFor(node) == 'US');
    await harness.controller.flush();
    final raw = await File(
      '${harness.directory.path}/${NodeCountryController.cacheFileName}',
    ).readAsString();
    expect(jsonDecode(raw), {
      'version': NodeCountryController.cacheVersion,
      'countries': {NodeCountryController.endpointKey(node): 'US'},
    });
    for (final secret in [
      node.name,
      node.server,
      _answer.ip,
      ...node.extra.values
    ]) {
      expect(raw, isNot(contains(secret)));
    }
  });

  test(
      'route identity normalizes host and excludes presentation but includes credentials',
      () {
    final node = _node(server: 'Relay.Example.Invalid.');
    expect(
      NodeCountryController.endpointKey(node),
      NodeCountryController.endpointKey(node.copyWith(
        name: 'changed',
        server: 'relay.example.invalid',
        type: ' HYSTERIA2 ',
      )),
    );
    for (final changed in [
      node.copyWith(extra: {...node.extra, 'password': 'rotated-credential'}),
      node.copyWith(extra: {...node.extra, 'sni': 'another-exit.example'}),
      node.copyWith(server: 'another.example.invalid'),
      node.copyWith(port: 8443),
      node.copyWith(type: 'ss'),
    ]) {
      expect(NodeCountryController.endpointKey(node),
          isNot(NodeCountryController.endpointKey(changed)));
    }
  });
}

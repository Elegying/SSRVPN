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
  _Request(this.host);
  final String host;
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
  Future<NodeCountryResolution?> lookup(String host) {
    final request = _Request(host);
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

  test('resolves at most two servers concurrently and drains remaining nodes',
      () async {
    final harness = await _Harness.create([
      for (var index = 0; index < 5; index++)
        _node(server: 'relay$index.example.invalid'),
    ]);
    harness.connect();
    await _until(() => harness.requests.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(harness.requests, hasLength(2));
    for (var index = 0; index < 5; index++) {
      await _until(() => harness.requests.length > index);
      expect(
          harness.requests.where((entry) => !entry.result.isCompleted).length,
          lessThanOrEqualTo(2));
      harness.requests[index].result.complete(_answer);
    }
    await _until(() => harness.lookups.single.closed);
    expect(harness.requests, hasLength(5));
    expect(
        harness.nodes.map(harness.controller.countryFor), everyElement('US'));
  });

  test('same server across endpoints shares one in-flight lookup', () async {
    final harness = await _Harness.create([_node(), _node(port: 8443)]);
    harness.connect();
    await _until(() => harness.requests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(harness.requests, hasLength(1));
    harness.requests.single.result.complete(_answer);
    await _until(() => harness.lookups.single.closed);
    expect(
        harness.nodes.map(harness.controller.countryFor), everyElement('US'));
  });

  test('immediate lookup batches yield so events can cancel remaining work',
      () async {
    final harness = await _Harness.create(
      [
        for (var index = 0; index < 100; index++)
          _node(server: 'relay$index.example.invalid'),
      ],
      immediateReply: true,
    );
    var eventQueued = false;
    var cancelled = false;
    harness.controller.addListener(() {
      if (eventQueued || harness.requests.isEmpty) return;
      eventQueued = true;
      Timer.run(() {
        harness.busy = true;
        harness.update();
        cancelled = true;
      });
    });

    harness.connect();
    await _until(() => cancelled);
    final started = harness.requests.length;
    expect(started, greaterThan(0));
    expect(started, lessThan(harness.nodes.length),
        reason:
            'An event must interrupt the batch before every lookup starts.');
    expect(harness.lookups.single.closed, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(harness.requests, hasLength(started));
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
    expect(harness.requests.last.host, moved.server);
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
      'version': 1,
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

  test('endpoint identity normalizes host but excludes names and credentials',
      () {
    final node = _node(server: 'Relay.Example.Invalid.');
    expect(
      NodeCountryController.endpointKey(node),
      NodeCountryController.endpointKey(node.copyWith(
        name: 'changed',
        server: 'relay.example.invalid',
        type: ' HYSTERIA2 ',
        extra: {'password': 'rotated-credential'},
      )),
    );
    for (final changed in [
      node.copyWith(server: 'another.example.invalid'),
      node.copyWith(port: 8443),
      node.copyWith(type: 'ss'),
    ]) {
      expect(NodeCountryController.endpointKey(node),
          isNot(NodeCountryController.endpointKey(changed)));
    }
  });
}

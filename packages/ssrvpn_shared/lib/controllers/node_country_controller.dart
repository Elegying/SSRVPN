import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/proxy_node.dart';
import '../services/node_country_lookup.dart';
import '../utils/node_country_policy.dart';
import '../utils/proxy_dependency_policy.dart';
import '../utils/recovering_serial_queue.dart';

/// Optional background enrichment, independent of connection and latency work.
/// Only successful endpoint-country pairs are persisted, without server names,
/// addresses, subscription URLs, credentials or node display names.
class NodeCountryController extends ChangeNotifier {
  NodeCountryController({
    this.stableDelay = const Duration(seconds: 15),
    NodeCountryLookup Function(int port)? lookupFactory,
  }) : _lookupFactory =
            lookupFactory ?? ((port) => NodeCountryLookup(proxyPort: port));

  static const cacheVersion = 2;
  static const cacheFileName = 'node-countries.json';
  static const _maxEntries = 10000;
  static const _maxCacheBytes = 1024 * 1024;
  final Duration stableDelay;
  final NodeCountryLookup Function(int port) _lookupFactory;
  final _writes = RecoveringSerialQueue();
  final _countries = <String, String>{};
  final _keys = <ProxyNode, String>{};
  final _hints = <ProxyNode, String>{};
  final _attempted = <String>{};
  List<ProxyNode>? _nodes;
  String _directory = '';
  Object? _session;
  ProxyNode? _selectedNode;
  String? _selectedKey;
  int? _resolvingEpoch;
  Future<String?> Function()? _currentSelectedProxyName;
  int _port = 0;
  int _epoch = 0;
  int _directoryEpoch = 0;
  bool _ready = false;
  bool _connected = false;
  bool _loaded = false;
  bool _disposed = false;
  bool Function()? _isConnectionCurrent;
  Timer? _timer;
  Timer? _saveTimer;
  NodeCountryLookup? _lookup;

  static String endpointKey(ProxyNode node) => sha256
      .convert(utf8.encode(jsonEncode([
        node.type.trim().toLowerCase(),
        node.server.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), ''),
        node.port,
        _routeOptions(node.extra),
      ])))
      .toString();

  // Shared relay endpoints can route different credentials/SNI to different
  // exits. Hash routing options, while excluding presentation/import metadata.
  static Object? _routeOptions(Object? value, {bool root = true}) {
    if (value is Map) {
      const metadata = {
        'name',
        'type',
        'server',
        'port',
        'group',
        'latency',
        'isOnline',
        'lastLatencyTest',
        'extra',
        'subscriptionUrl',
        'ssrvpn-subscription',
        'ssrvpn-subscription-ids',
        'ssrvpn-original-name',
        'country',
        'countryCode',
        'country-code',
        'region',
        'regionCode',
        'ipCountry',
      };
      final keys = value.keys
          .cast<String>()
          .where((key) => !root || !metadata.contains(key))
          .toList()
        ..sort();
      return {
        for (final key in keys) key: _routeOptions(value[key], root: false)
      };
    }
    if (value is List) {
      return value.map((entry) => _routeOptions(entry, root: false)).toList();
    }
    return value;
  }

  void _indexNodes(List<ProxyNode> nodes) {
    _keys
      ..clear()
      ..addEntries(nodes.map((node) => MapEntry(node, endpointKey(node))));
    if (!nodes.any((node) => node.extra['dialer-proxy'] != null)) return;
    final proxies = {
      for (final node in nodes)
        {
          ...node.extra,
          'name': node.name,
          'type': node.type,
          'server': node.server,
          'port': node.port,
        }: node
    };
    try {
      for (final (proxy, parent)
          in ProxyDependencyPolicy.resolve(proxies.keys)) {
        if (parent == null) continue;
        final node = proxies[proxy]!;
        _keys[node] = sha256
            .convert(utf8.encode(jsonEncode([
              _keys[node],
              _keys[proxies[parent]],
            ])))
            .toString();
      }
    } on FormatException {
      // Invalid dependency graphs cannot be loaded by the core either.
      _keys.clear();
    }
  }

  String countryFor(ProxyNode node) =>
      _countries[_keys[node] ?? endpointKey(node)] ??
      (_hints[node] ??= countryCodeForProxyNode(node));

  /// Safe during widget builds: this never synchronously notifies listeners.
  void update({
    required List<ProxyNode> nodes,
    required ProxyNode? selectedNode,
    required Future<String?> Function() currentSelectedProxyName,
    required bool connected,
    required bool busy,
    required Object? session,
    required int proxyPort,
    required String cacheDirectory,
    required bool Function() isConnectionCurrent,
  }) {
    if (_disposed) return;
    final selectedName = selectedNode?.name;
    selectedNode = nodes.where((node) => node.name == selectedName).firstOrNull;
    final directoryChanged = cacheDirectory != _directory;
    final nodesChanged = !identical(nodes, _nodes);
    if (nodesChanged) {
      _nodes = nodes;
      _indexNodes(nodes);
      _hints.clear();
    }
    final selectedKey = selectedNode == null
        ? null
        : (_keys[selectedNode] ?? endpointKey(selectedNode));
    final selectedChanged = selectedNode?.name != _selectedNode?.name ||
        selectedKey != _selectedKey;
    final ready = connected &&
        !busy &&
        selectedNode != null &&
        proxyPort > 0 &&
        proxyPort <= 65535;
    _currentSelectedProxyName = currentSelectedProxyName;
    _isConnectionCurrent = isConnectionCurrent;
    if (directoryChanged ||
        nodesChanged ||
        selectedChanged ||
        ready != _ready ||
        session != _session ||
        proxyPort != _port) {
      _cancel();
    }
    if (session != _session || directoryChanged || (connected && !_connected)) {
      _attempted.clear();
    }
    _selectedNode = selectedNode;
    _selectedKey = selectedKey;
    _connected = connected;
    _session = session;
    _port = proxyPort;
    _ready = ready;
    if (directoryChanged) {
      unawaited(flush());
      _directory = cacheDirectory;
      _countries.clear();
      _loaded = false;
      _directoryEpoch++;
      if (_directory.isNotEmpty) {
        unawaited(_load(_directory, _directoryEpoch));
      }
    }
    _schedule();
  }

  bool get _eligible =>
      !_disposed &&
      _ready &&
      _loaded &&
      (_isConnectionCurrent?.call() ?? false);

  void _schedule() {
    if (!_eligible || _timer != null || _resolvingEpoch != null) return;
    final node = _selectedNode;
    if (node == null) return;
    final key = _keys[node] ?? endpointKey(node);
    if (_countries.containsKey(key) || _attempted.contains(key)) {
      return;
    }
    _timer = Timer(stableDelay, () {
      _timer = null;
      if (_eligible) unawaited(_resolve(_epoch));
    });
  }

  Future<void> _resolve(int epoch) async {
    final node = _selectedNode;
    if (node == null) return;
    final key = _keys[node] ?? endpointKey(node);
    final selectedName = _currentSelectedProxyName!;
    _resolvingEpoch = epoch;
    NodeCountryLookup? lookup;
    bool current() => _eligible && epoch == _epoch;
    try {
      // UI selection can lag tray/recovery changes. Confirm the actual core
      // route on both sides of the request; never label other catalog nodes.
      if (!current() || await selectedName() != node.name || !current()) return;
      lookup = _lookupFactory(_port);
      _lookup = lookup;
      final result = await lookup.lookup();
      if (!current() || await selectedName() != node.name || !current()) return;
      _attempted.add(key);
      final code = normalizeNodeCountryCode(result?.countryCode ?? '');
      if (result == null ||
          code == 'UN' ||
          !isPublicNodeCountryAddress(result.ip)) {
        return;
      }
      _countries[key] = code;
      while (_countries.length > _maxEntries) {
        _countries.remove(_countries.keys.first);
      }
      _saveTimer ??= Timer(const Duration(seconds: 1), () {
        _saveTimer = null;
        unawaited(flush());
      });
      notifyListeners();
    } catch (_) {
      if (current()) _attempted.add(key);
      // Country enrichment must never fail a connection or a latency test.
    } finally {
      lookup?.close();
      if (identical(_lookup, lookup)) _lookup = null;
      if (_resolvingEpoch == epoch) _resolvingEpoch = null;
    }
  }

  Future<void> _load(String directory, int directoryEpoch) async {
    final entries = <String, String>{};
    try {
      await _writes.add(() async {});
      final file = File('$directory/$cacheFileName');
      if (await file.exists() && await file.length() <= _maxCacheBytes) {
        final input = await file.open();
        late List<int> bytes;
        try {
          bytes = await input.read(_maxCacheBytes + 1);
        } finally {
          await input.close();
        }
        if (bytes.length > _maxCacheBytes) throw const FormatException();
        final json = jsonDecode(utf8.decode(bytes));
        if (json is Map &&
            json['version'] == cacheVersion &&
            json['countries'] is Map) {
          for (final entry
              in (json['countries'] as Map).entries.take(_maxEntries)) {
            if (entry.key is! String ||
                entry.value is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String)) {
              continue;
            }
            final code = normalizeNodeCountryCode(entry.value as String);
            if (code != 'UN') entries[entry.key as String] = code;
          }
        }
      }
    } catch (_) {
      // Invalid/unreadable cache only disables reuse; it never blocks startup.
    }
    if (_disposed || _directoryEpoch != directoryEpoch) return;
    _countries.addAll(entries);
    _loaded = true;
    notifyListeners();
    _schedule();
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_directory.isEmpty || !_loaded) return Future<void>.value();
    final file = File('$_directory/$cacheFileName');
    final contents =
        jsonEncode({'version': cacheVersion, 'countries': _countries});
    return _writes.add(() async {
      final temporary = File('${file.path}.tmp');
      try {
        await file.parent.create(recursive: true);
        await temporary.writeAsString(contents, flush: true);
        await temporary.rename(file.path);
      } catch (_) {
        // Read-only storage must not affect live connectivity or UI.
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    });
  }

  void _cancel() {
    _epoch++;
    _resolvingEpoch = null;
    _timer?.cancel();
    _timer = null;
    _lookup?.close();
    _lookup = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel();
    unawaited(flush());
    super.dispose();
  }
}

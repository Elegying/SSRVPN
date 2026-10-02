import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/proxy_node.dart';
import '../utils/recovering_serial_queue.dart';
import 'node_latency_cache.dart';

/// Optional display preferences. Never changes subscriptions or runtime YAML.
class NodePinStore extends ChangeNotifier {
  NodePinStore(this.directory);
  final String directory;
  static final _queues = <String, RecoveringSerialQueue>{};
  RecoveringSerialQueue get _writes => _queues.putIfAbsent(
      Directory(directory).absolute.path, RecoveringSerialQueue.new);
  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Set<String> _keys = {};
  Future<void>? _loading;
  static const maxEntries = 10000;
  static const maxBytes = 800000;
  static const fileName = 'node-pins.json';
  bool contains(ProxyNode node) =>
      _keys.contains(NodeLatencyCache.endpointKey(node));
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      final file = File('$directory/$fileName');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > maxBytes) {
        return;
      }
      final bytes = <int>[];
      await for (final chunk in file.openRead()) {
        if (bytes.length + chunk.length > maxBytes) return;
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map || data['version'] != 1 || data['pins'] is! List) return;
      final pins = data['pins'] as List;
      if (pins.length > maxEntries ||
          pins.any(
            (key) => key is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key),
          )) {
        return;
      }
      _keys = pins.cast<String>().toSet();
      if (!_disposed) notifyListeners();
    } catch (_) {
      /* Optional preferences cannot block connection. */
    }
  }

  Future<void> toggle(ProxyNode node) => _writes.add(() async {
        await load();
        await _load();
        final key = NodeLatencyCache.endpointKey(node);
        final next = Set<String>.of(_keys);
        if (!next.remove(key)) {
          if (next.length >= maxEntries) {
            throw const FormatException('置顶数量已达上限');
          }
          next.add(key);
        }
        final root = Directory(directory);
        await root.create(recursive: true);
        final file = File('$directory/$fileName');
        final kind = await FileSystemEntity.type(file.path, followLinks: false);
        if (kind != FileSystemEntityType.notFound &&
            kind != FileSystemEntityType.file) {
          throw const FileSystemException('Invalid pin store');
        }
        final temp = await root.createTemp('node-pins-');
        try {
          final staged = File('${temp.path}/pins.json');
          await staged.writeAsString(
            jsonEncode({'version': 1, 'pins': next.toList()}),
            flush: true,
          );
          await staged.rename(file.path);
          _keys = next;
          if (!_disposed) notifyListeners();
        } finally {
          try {
            await temp.delete(recursive: true);
          } catch (_) {}
        }
      });
}

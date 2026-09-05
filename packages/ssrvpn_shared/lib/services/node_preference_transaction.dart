import 'dart:convert';
import 'dart:io';

import '../models/app_settings.dart';
import '../utils/bounded_yaml.dart';
import '../utils/runtime_config_name_policy.dart';

/// Implemented by each platform's serialized settings store. The settings
/// queue stays held until the subscription has durably committed the edit.
abstract interface class NodePreferenceStore {
  Future<void> withNodePreferenceRename(NodePreferenceRename change,
      Future<void> Function(NodePreferenceWrite write) edit);
  Future<void> recoverNodePreference(NodePreferenceRename change);
}

class NodePreferenceRename {
  const NodePreferenceRename(this.originalName, this.updatedName, this.id);

  final String originalName;
  final String updatedName;
  final String id;

  Map<String, dynamic> toJson() => {
        'originalName': originalName,
        'updatedName': updatedName,
        'id': id,
      };

  factory NodePreferenceRename.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('首选节点恢复记录无效');
    final original = value['originalName'];
    final updated = value['updatedName'];
    final id = value['id'];
    for (final name in [original, updated]) {
      if (name is! String ||
          name.isEmpty ||
          RuntimeConfigNamePolicy.canonicalName(name) != name) {
        throw const FormatException('首选节点恢复名称无效');
      }
    }
    if (id is! String || !RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(id)) {
      throw const FormatException('首选节点恢复标识无效');
    }
    return NodePreferenceRename(original as String, updated as String, id);
  }

  /// Only compensate this write. A later independent selection clears the ID
  /// and must survive retries of a previously interrupted recovery.
  bool recoverJson(Map<String, dynamic> settings) {
    if (settings['lastSelectedNodeRenameId'] != id ||
        settings['lastSelectedNodeName'] != updatedName) {
      return false;
    }
    settings['lastSelectedNodeName'] = originalName;
    settings['lastSelectedNodeRenameId'] = '';
    return true;
  }
}

class NodePreferenceWrite {
  NodePreferenceWrite({
    required AppSettings current,
    required NodePreferenceRename change,
    required Future<void> Function(AppSettings) write,
    required void Function(AppSettings) publish,
  })  : _write = write,
        _publish = publish,
        _candidate = RuntimeConfigNamePolicy.canonicalName(
                    current.lastSelectedNodeName) ==
                change.originalName
            ? current.copyWith(
                lastSelectedNodeName: change.updatedName,
                lastSelectedNodeRenameId: change.id)
            : null;

  final AppSettings? _candidate;
  final Future<void> Function(AppSettings) _write;
  final void Function(AppSettings) _publish;

  bool get changesPreference => _candidate != null;

  Future<void> persist() async {
    final candidate = _candidate;
    if (candidate != null) await _write(candidate);
  }

  /// Called synchronously with subscription publication, after journal removal.
  void publish() {
    final candidate = _candidate;
    if (candidate != null) _publish(candidate);
  }

  static Future<void> recover({
    required NodePreferenceRename change,
    required AppSettings current,
    required File file,
    required Future<void> Function(AppSettings) write,
    required void Function(AppSettings) publish,
  }) async {
    // Read disk as well as memory: an atomic replacement can succeed before a
    // subsequent durability check reports failure to the original writer.
    final stored = await readSettings(file);
    if (stored == null || !change.recoverJson(stored)) return;
    final restored = current.copyWith(
        lastSelectedNodeName: change.originalName,
        lastSelectedNodeRenameId: '');
    await write(restored);
    publish(restored);
  }

  static Future<Map<String, dynamic>?> readSettings(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file ||
        await file.length() > BoundedYaml.maxInputBytes) {
      throw const FileSystemException('无法安全读取首选节点恢复状态');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) throw const FormatException('首选节点设置无效');
    return value;
  }
}

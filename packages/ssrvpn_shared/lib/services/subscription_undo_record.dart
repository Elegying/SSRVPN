import 'dart:convert';
import 'dart:io';

import '../utils/bounded_yaml.dart';
import 'node_preference_transaction.dart';

/// Shared by normal startup and read-only-source Windows data migration.
class SubscriptionUndoRecord {
  const SubscriptionUndoRecord(this.files, this.preference);

  static const fileName = 'subscription_transaction.json';
  static const stateFiles = ['subscriptions.json', 'subscription_cache.yaml'];
  final Map<String, String?> files;
  final NodePreferenceRename? preference;

  static Future<SubscriptionUndoRecord?> read(File journal) async {
    final type = await FileSystemEntity.type(journal.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file ||
        await journal.length() > BoundedYaml.maxInputBytes * 8) {
      throw const FileSystemException('订阅恢复记录类型或大小无效');
    }
    final data = jsonDecode(await journal.readAsString());
    if (data is! Map ||
        ![1, 2].contains(data['version']) ||
        data['files'] is! Map) {
      throw const FormatException('订阅恢复记录无效');
    }
    final source = data['files'] as Map;
    final files = <String, String?>{};
    for (final name in stateFiles) {
      final content = source[name];
      if (!source.containsKey(name) ||
          (content != null && content is! String) ||
          (content is String &&
              utf8.encode(content).length > BoundedYaml.maxInputBytes)) {
        throw const FormatException('订阅恢复记录内容无效');
      }
      files[name] = content as String?;
    }
    return SubscriptionUndoRecord(
        Map.unmodifiable(files),
        data['version'] == 2
            ? NodePreferenceRename.fromJson(data['preference'])
            : null);
  }
}

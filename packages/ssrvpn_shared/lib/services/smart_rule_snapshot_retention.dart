import 'dart:io';
import 'dart:isolate';

import '../utils/bounded_yaml.dart';
import 'smart_rule_bundle.dart';

/// Startup-only collection. No configuration producer may be admitted until
/// this completes. Native starts can only claim existing immutable configs,
/// all of whose provider references are retained, including idle tile configs.
abstract final class SmartRuleSnapshotRetention {
  static Future<int> prune(
    String configDir, {
    required Set<String> protectedVersions,
    required List<String> protectedConfigPaths,
    required Set<String> fileNames,
  }) =>
      Isolate.run(() => _prune(
          configDir, protectedVersions, protectedConfigPaths, fileNames));

  static int _prune(String configDir, Set<String> protectedVersions,
      List<String> protectedConfigPaths, Set<String> fileNames) {
    final clock = Stopwatch()..start();
    final root = Directory(configDir).resolveSymbolicLinksSync();
    final providers = '$root${Platform.pathSeparator}providers';
    final bundles = '$providers${Platform.pathSeparator}bundles';
    for (final path in [providers, bundles]) {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.directory ||
          Directory(path).resolveSymbolicLinksSync() != path) {
        return 0;
      }
    }
    var entries = 0;
    var bytes = 0;
    final protected = Set<String>.of(protectedVersions);
    final configs = <String>{};
    void budget() {
      if (++entries > 512 || clock.elapsedMilliseconds > 200) {
        throw const FormatException('规则快照清理超过扫描预算');
      }
    }

    void readConfig(String path, {bool requiredConfig = false}) {
      if (!configs.add(path)) return;
      budget();
      if (!path.startsWith('$root${Platform.pathSeparator}') ||
          FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.file ||
          File(path).resolveSymbolicLinksSync() != path) {
        throw const FormatException('规则快照引用路径无法确认');
      }
      final file = File(path);
      bytes += file.lengthSync();
      if (bytes > 32 * 1024 * 1024) {
        throw const FormatException('规则快照配置超过扫描预算');
      }
      final document = BoundedYaml.load(file.readAsStringSync());
      if (document is! Map) {
        if (requiredConfig) throw const FormatException('规则快照配置无效');
        // The same directory also holds subscriptions.json (a list). A valid
        // non-map document cannot be a core config or own provider references.
        return;
      }
      final ruleProviders = document['rule-providers'];
      if (ruleProviders == null) return;
      if (ruleProviders is! Map) {
        throw const FormatException('规则快照 provider 引用无效');
      }
      for (final provider in ruleProviders.values) {
        final path = provider is Map ? provider['path'] : null;
        if (path is! String) {
          throw const FormatException('规则快照 provider 路径无效');
        }
        if (!path.toLowerCase().contains('bundles')) continue;
        final match =
            RegExp(r'^\./providers/bundles/([^/]+)/([^/]+)$').firstMatch(path);
        if (match == null || !fileNames.contains(match[2])) {
          throw const FormatException('规则快照版本引用无法确认');
        }
        SmartRuleBundle.providerPathPrefix(match[1]!);
        protected.add(match[1]!);
      }
    }

    void scan(Directory dir) {
      for (final entity in dir.listSync(followLinks: false)) {
        budget();
        if (entity.path == providers) continue;
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          throw const FormatException('规则快照扫描遇到链接，保留全部快照');
        }
        if (type == FileSystemEntityType.directory) {
          scan(Directory(entity.path));
        } else if (RegExp(r'\.(yaml|yml|json)$', caseSensitive: false)
            .hasMatch(entity.path)) {
          readConfig(entity.path);
        }
      }
    }

    // Finish the entire reference scan before mutating any bundle. Read or
    // resource failures must not turn an incomplete keep set into deletion.
    // Validate explicit native references first so a discovered non-config
    // cannot be cached as already inspected and bypass this stricter check.
    for (final path in protectedConfigPaths) {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('原生规则快照引用不是普通文件');
      }
      readConfig(File(path).resolveSymbolicLinksSync(), requiredConfig: true);
    }
    scan(Directory(root));
    final versions = <String, Directory>{};
    for (final entity in Directory(bundles).listSync(followLinks: false)) {
      budget();
      if (entity is! Directory) continue;
      final version = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      try {
        SmartRuleBundle.providerPathPrefix(version);
      } on ArgumentError {
        continue; // Unknown directories belong to neither this GC nor a version.
      }
      if (entity.resolveSymbolicLinksSync() != entity.path) continue;
      final contents = entity.listSync(followLinks: false);
      if (contents.length != fileNames.length ||
          contents.any((file) =>
              !fileNames.contains(file.uri.pathSegments.last) ||
              FileSystemEntity.typeSync(file.path, followLinks: false) !=
                  FileSystemEntityType.file)) {
        continue;
      }
      versions[version] = entity;
    }
    final unreferenced =
        versions.keys.where((v) => !protected.contains(v)).toList()
          ..sort((a, b) {
            final left = a.split('.').map(int.parse).toList();
            final right = b.split('.').map(int.parse).toList();
            for (var i = 0; i < 3; i++) {
              final order = right[i].compareTo(left[i]);
              if (order != 0) return order;
            }
            return 0;
          });
    var removed = 0;
    for (final version in unreferenced.skip(2)) {
      budget();
      final dir = versions[version]!;
      final contents = dir.listSync(followLinks: false);
      if (contents.isEmpty ||
          contents.length > fileNames.length ||
          contents.any((entity) =>
              !fileNames.contains(entity.uri.pathSegments.last) ||
              FileSystemEntity.typeSync(entity.path, followLinks: false) !=
                  FileSystemEntityType.file)) {
        continue;
      }
      for (final file in contents) {
        if (dir.resolveSymbolicLinksSync() != dir.path ||
            FileSystemEntity.typeSync(file.path, followLinks: false) !=
                FileSystemEntityType.file) {
          throw const FormatException('规则快照目录身份变化，停止清理');
        }
        // Flat owned files only. Never recursively follow arbitrary children.
        file.deleteSync();
      }
      dir.deleteSync();
      removed++;
    }
    return removed;
  }
}

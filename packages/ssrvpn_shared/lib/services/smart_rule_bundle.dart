import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

class SmartRuleBundleInstallResult {
  const SmartRuleBundleInstallResult({
    required this.version,
    required this.installedFiles,
    required this.reusedFiles,
  });

  final String version;
  final int installedFiles;
  final int reusedFiles;
}

class SmartRuleVersionDescriptor {
  const SmartRuleVersionDescriptor({
    required this.version,
    required this.manifestSha256,
  });

  final String version;
  final String manifestSha256;

  bool acceptsManifest(String manifestText) =>
      crypto.sha256.convert(utf8.encode(manifestText)).toString() ==
      manifestSha256;

  bool isNewerThan(String? installedVersion) {
    if (installedVersion == null) return true;
    final remote = version.split('.').map(int.parse).toList(growable: false);
    final local =
        installedVersion.split('.').map(int.parse).toList(growable: false);
    for (var index = 0; index < remote.length; index++) {
      if (remote[index] != local[index]) return remote[index] > local[index];
    }
    return false;
  }
}

class SmartRuleManifestEntry {
  const SmartRuleManifestEntry({
    required this.name,
    required this.behavior,
    required this.count,
    required this.sha256,
  });

  final String name;
  final String behavior;
  final int count;
  final String sha256;

  bool hasSameContentAs(SmartRuleManifestEntry? other) =>
      other != null &&
      behavior == other.behavior &&
      count == other.count &&
      sha256 == other.sha256;
}

class SmartRuleManifest {
  const SmartRuleManifest({required this.version, required this.files});

  final String version;
  final Map<String, SmartRuleManifestEntry> files;
}

/// Installs and tracks a verified local baseline for remotely refreshable rules.
///
/// Existing valid files are retained because Mihomo may have refreshed them to
/// a newer reviewed rules-channel version. Missing, linked, oversized, or
/// malformed files are replaced from the signed application bundle so a first
/// connection never depends on remote rule availability. The active manifest
/// is written only after every provider matches it, making its version a durable
/// commit marker rather than an optimistic download record.
class SmartRuleBundle {
  static const String assetPrefix =
      'packages/ssrvpn_shared/assets/rules/latest';
  static const String installedManifestFileName =
      'ssrvpn-smart-rules-manifest.json';
  static const int maxProviderBytes = 2 * 1024 * 1024;
  static const int maxManifestBytes = 64 * 1024;
  static const int maxVersionDescriptorBytes = 4 * 1024;
  static final RegExp _safeFileName = RegExp(r'^[a-z][a-z0-9_]*\.yaml$');
  static final RegExp _semanticVersion = RegExp(r'^\d+\.\d+\.\d+$');
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _domainRule =
      RegExp(r'^(?:\+\.)?[a-z0-9_*?][a-z0-9._*?+-]*$');

  static SmartRuleVersionDescriptor parseVersionDescriptor(String text) {
    if (utf8.encode(text).length > maxVersionDescriptorBytes) {
      throw const FormatException('智能规则版本文件过大');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != 1) {
      throw const FormatException('智能规则版本文件格式无效');
    }
    final version = decoded['version'];
    final manifestSha256 = decoded['manifestSha256'];
    if (version is! String ||
        !_semanticVersion.hasMatch(version) ||
        manifestSha256 is! String ||
        !_sha256.hasMatch(manifestSha256)) {
      throw const FormatException('智能规则版本文件字段无效');
    }
    return SmartRuleVersionDescriptor(
      version: version,
      manifestSha256: manifestSha256,
    );
  }

  static SmartRuleManifest parseManifest(
    String text, {
    Set<String>? expectedFileNames,
  }) {
    if (utf8.encode(text).length > maxManifestBytes) {
      throw const FormatException('智能规则清单过大');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != 1) {
      throw const FormatException('智能规则清单版本无效');
    }
    final version = decoded['version'];
    final rawFiles = decoded['files'];
    if (version is! String ||
        !_semanticVersion.hasMatch(version) ||
        rawFiles is! List ||
        rawFiles.isEmpty) {
      throw const FormatException('智能规则清单内容无效');
    }

    final files = <String, SmartRuleManifestEntry>{};
    for (final rawEntry in rawFiles) {
      if (rawEntry is! Map) {
        throw const FormatException('智能规则文件清单格式无效');
      }
      final entry = rawEntry.cast<Object?, Object?>();
      final name = entry['name'];
      final behavior = entry['behavior'];
      final count = entry['count'];
      final expectedHash = entry['sha256'];
      if (name is! String ||
          !_safeFileName.hasMatch(name) ||
          files.containsKey(name) ||
          (behavior != 'domain' && behavior != 'ipcidr') ||
          count is! int ||
          count <= 0 ||
          count > 100000 ||
          expectedHash is! String ||
          !_sha256.hasMatch(expectedHash)) {
        throw const FormatException('智能规则文件清单字段无效');
      }
      files[name] = SmartRuleManifestEntry(
        name: name,
        behavior: behavior as String,
        count: count,
        sha256: expectedHash,
      );
    }
    if (expectedFileNames != null &&
        (files.length != expectedFileNames.length ||
            !files.keys.every(expectedFileNames.contains))) {
      throw const FormatException('智能规则文件集合不完整或包含未知文件');
    }
    return SmartRuleManifest(version: version, files: files);
  }

  static Future<SmartRuleBundleInstallResult> ensureInstalled(
    String configDir, {
    AssetBundle? assetBundle,
  }) async {
    final bundle = assetBundle ?? rootBundle;
    final manifestText = await bundle.loadString('$assetPrefix/manifest.json');
    final manifest = parseManifest(manifestText);

    final providersDir = Directory(
      '$configDir${Platform.pathSeparator}providers',
    );
    await providersDir.create(recursive: true);
    var installed = 0;
    var reused = 0;

    for (final entry in manifest.files.values) {
      final destination = File(
        '${providersDir.path}${Platform.pathSeparator}${entry.name}',
      );
      if (await _isValidProviderFile(destination, entry.behavior)) {
        reused++;
        continue;
      }

      final asset = await bundle.load('$assetPrefix/${entry.name}');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      if (bytes.isEmpty || bytes.length > maxProviderBytes) {
        throw FormatException('内置智能规则大小无效: ${entry.name}');
      }
      if (crypto.sha256.convert(bytes).toString() != entry.sha256) {
        throw FormatException('内置智能规则摘要不匹配: ${entry.name}');
      }
      if (!_isValidProviderBytes(
        bytes,
        entry.behavior,
        expectedCount: entry.count,
      )) {
        throw FormatException('内置智能规则内容无效: ${entry.name}');
      }
      await _replaceFile(destination, bytes);
      installed++;
    }

    final expectedFileNames = manifest.files.keys.toSet();
    final installedVersion = await readInstalledVersion(
      configDir,
      expectedFileNames: expectedFileNames,
    );
    if (installedVersion == null) {
      await activateInstalledManifest(
        configDir,
        manifestText,
        expectedFileNames: expectedFileNames,
      );
    }

    return SmartRuleBundleInstallResult(
      version: manifest.version,
      installedFiles: installed,
      reusedFiles: reused,
    );
  }

  /// Returns a version only when the durable manifest and every active provider
  /// still match exactly. Invalid or legacy state is treated as unknown so the
  /// next background check can safely repair it.
  static Future<String?> readInstalledVersion(
    String configDir, {
    required Set<String> expectedFileNames,
  }) async =>
      (await readInstalledManifest(
        configDir,
        expectedFileNames: expectedFileNames,
      ))
          ?.version;

  /// Returns the active manifest only when it and every provider still match.
  /// Callers can use its per-file hashes to avoid refreshing unchanged files.
  static Future<SmartRuleManifest?> readInstalledManifest(
    String configDir, {
    required Set<String> expectedFileNames,
  }) async {
    try {
      final file = _installedManifest(configDir);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final length = await file.length();
      if (length <= 0 || length > maxManifestBytes) return null;
      final text = await file.readAsString();
      final manifest = parseManifest(
        text,
        expectedFileNames: expectedFileNames,
      );
      return await _matchesInstalledProviders(configDir, manifest)
          ? manifest
          : null;
    } on Object {
      return null;
    }
  }

  /// Activates [manifestText] only after all provider files match its hashes,
  /// counts, and syntax. A mismatch returns false and leaves the previous
  /// durable manifest untouched.
  static Future<bool> activateInstalledManifest(
    String configDir,
    String manifestText, {
    required Set<String> expectedFileNames,
  }) async {
    final manifest = parseManifest(
      manifestText,
      expectedFileNames: expectedFileNames,
    );
    if (!await _matchesInstalledProviders(configDir, manifest)) return false;
    await _replaceFile(
        _installedManifest(configDir), utf8.encode(manifestText));
    return true;
  }

  static File _installedManifest(String configDir) => File(
        '$configDir${Platform.pathSeparator}providers'
        '${Platform.pathSeparator}$installedManifestFileName',
      );

  static Future<bool> _matchesInstalledProviders(
    String configDir,
    SmartRuleManifest manifest,
  ) async {
    final providersDir =
        '$configDir${Platform.pathSeparator}providers${Platform.pathSeparator}';
    for (final entry in manifest.files.values) {
      final file = File('$providersDir${entry.name}');
      if (!await _isValidProviderFile(
        file,
        entry.behavior,
        expectedCount: entry.count,
        expectedHash: entry.sha256,
      )) {
        return false;
      }
    }
    return true;
  }

  static Future<bool> _isValidProviderFile(
    File file,
    String behavior, {
    int? expectedCount,
    String? expectedHash,
  }) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final length = await file.length();
      if (length <= 0 || length > maxProviderBytes) return false;
      final bytes = await file.readAsBytes();
      if (expectedHash != null &&
          crypto.sha256.convert(bytes).toString() != expectedHash) {
        return false;
      }
      return _isValidProviderBytes(
        bytes,
        behavior,
        expectedCount: expectedCount,
      );
    } on Object {
      return false;
    }
  }

  static bool _isValidProviderBytes(
    List<int> bytes,
    String behavior, {
    int? expectedCount,
  }) {
    try {
      final decoded = utf8.decode(bytes);
      final yaml = loadYaml(decoded);
      if (yaml is! YamlMap) return false;
      final payload = yaml['payload'];
      if (payload is! YamlList ||
          payload.isEmpty ||
          payload.length > 100000 ||
          (expectedCount != null && payload.length != expectedCount)) {
        return false;
      }
      final seen = <String>{};
      for (final value in payload) {
        if (value is! String || value.isEmpty || !seen.add(value)) return false;
        if (behavior == 'domain') {
          if (value != value.toLowerCase() || !_domainRule.hasMatch(value)) {
            return false;
          }
        } else if (!_isValidCidr(value)) {
          return false;
        }
      }
      return true;
    } on Object {
      return false;
    }
  }

  static bool _isValidCidr(String value) {
    final separator = value.lastIndexOf('/');
    if (separator <= 0 || separator == value.length - 1) return false;
    final address = InternetAddress.tryParse(value.substring(0, separator));
    final prefix = int.tryParse(value.substring(separator + 1));
    if (address == null || prefix == null) return false;
    final maxPrefix = address.type == InternetAddressType.IPv4 ? 32 : 128;
    return prefix >= 0 && prefix <= maxPrefix;
  }

  static Future<void> _replaceFile(File destination, List<int> bytes) async {
    await destination.parent.create(recursive: true);
    final temp = File(
      '${destination.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.create(exclusive: true);
      await temp.writeAsBytes(bytes, flush: true);
      final type = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        await Directory(destination.path).delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await Link(destination.path).delete();
      } else if (type != FileSystemEntityType.notFound) {
        await destination.delete();
      }
      await temp.rename(destination.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}

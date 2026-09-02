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

/// Installs a verified local baseline for every remotely refreshable rule set.
///
/// Existing valid files are retained because Mihomo may have refreshed them to
/// a newer reviewed rules-channel version. Missing, linked, oversized, or
/// malformed files are replaced from the signed application bundle so a first
/// connection never depends on remote rule availability.
class SmartRuleBundle {
  static const String assetPrefix =
      'packages/ssrvpn_shared/assets/rules/latest';
  static const int maxProviderBytes = 2 * 1024 * 1024;
  static final RegExp _safeFileName = RegExp(r'^[a-z][a-z0-9_]*\.yaml$');
  static final RegExp _domainRule =
      RegExp(r'^(?:\+\.)?[a-z0-9_*?][a-z0-9._*?+-]*$');

  static Future<SmartRuleBundleInstallResult> ensureInstalled(
    String configDir, {
    AssetBundle? assetBundle,
  }) async {
    final bundle = assetBundle ?? rootBundle;
    final manifestText = await bundle.loadString('$assetPrefix/manifest.json');
    final manifest = jsonDecode(manifestText);
    if (manifest is! Map<String, dynamic> || manifest['schemaVersion'] != 1) {
      throw const FormatException('智能规则清单版本无效');
    }
    final version = manifest['version'];
    final files = manifest['files'];
    if (version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        files is! List ||
        files.isEmpty) {
      throw const FormatException('智能规则清单内容无效');
    }

    final providersDir = Directory(
      '$configDir${Platform.pathSeparator}providers',
    );
    await providersDir.create(recursive: true);
    var installed = 0;
    var reused = 0;
    final seenNames = <String>{};

    for (final rawEntry in files) {
      if (rawEntry is! Map) {
        throw const FormatException('智能规则文件清单格式无效');
      }
      final entry = rawEntry.cast<Object?, Object?>();
      final name = entry['name'];
      final behavior = entry['behavior'];
      final expectedHash = entry['sha256'];
      if (name is! String ||
          !_safeFileName.hasMatch(name) ||
          !seenNames.add(name) ||
          (behavior != 'domain' && behavior != 'ipcidr') ||
          expectedHash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash)) {
        throw const FormatException('智能规则文件清单字段无效');
      }

      final destination = File(
        '${providersDir.path}${Platform.pathSeparator}$name',
      );
      if (await _isValidProviderFile(destination, behavior as String)) {
        reused++;
        continue;
      }

      final asset = await bundle.load('$assetPrefix/$name');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      if (bytes.isEmpty || bytes.length > maxProviderBytes) {
        throw FormatException('内置智能规则大小无效: $name');
      }
      if (crypto.sha256.convert(bytes).toString() != expectedHash) {
        throw FormatException('内置智能规则摘要不匹配: $name');
      }
      if (!_isValidProviderBytes(bytes, behavior)) {
        throw FormatException('内置智能规则内容无效: $name');
      }
      await _replaceFile(destination, bytes);
      installed++;
    }

    return SmartRuleBundleInstallResult(
      version: version,
      installedFiles: installed,
      reusedFiles: reused,
    );
  }

  static Future<bool> _isValidProviderFile(
    File file,
    String behavior,
  ) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final length = await file.length();
      if (length <= 0 || length > maxProviderBytes) return false;
      return _isValidProviderBytes(await file.readAsBytes(), behavior);
    } on Object {
      return false;
    }
  }

  static bool _isValidProviderBytes(List<int> bytes, String behavior) {
    try {
      final decoded = utf8.decode(bytes);
      final yaml = loadYaml(decoded);
      if (yaml is! YamlMap) return false;
      final payload = yaml['payload'];
      if (payload is! YamlList || payload.isEmpty || payload.length > 100000) {
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

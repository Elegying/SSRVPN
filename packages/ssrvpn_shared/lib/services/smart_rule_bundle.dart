import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';
import '../utils/bounded_yaml.dart';

class SmartRuleBundleInstallResult {
  const SmartRuleBundleInstallResult({
    required this.version,
    required this.activeVersion,
    required this.providerPathPrefix,
    required this.installedFiles,
    required this.reusedFiles,
  });

  final String version;
  final String? activeVersion;
  final String? providerPathPrefix;
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
  const SmartRuleManifest(
      {required this.version,
      required this.files,
      this.componentVersions = const {}});

  final String version;
  final Map<String, SmartRuleManifestEntry> files;
  final Map<String, String> componentVersions;
}

/// Installs and tracks a verified local baseline for remotely refreshable rules.
///
/// Every complete version lives in its own immutable directory. The active
/// manifest is written only after all providers in that directory match it, so
/// a partial download or write can never mix rule versions in a running config.
/// Older root-level providers remain readable for migration and rollback.
class SmartRuleBundle {
  static const androidFiles = {'direct_apps.yaml', 'proxy_apps.yaml'};
  static final packageNamePattern =
      RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$');
  static const excludedPackages = {
    'com.android.chrome',
    'com.chrome.beta',
    'com.chrome.dev',
    'com.chrome.canary',
    'com.google.android.apps.chrome',
    'com.microsoft.emmx',
    'org.mozilla.firefox',
    'org.mozilla.fenix',
    'org.mozilla.focus',
    'com.brave.browser',
    'com.opera.browser',
    'com.opera.mini.native',
    'com.sec.android.app.sbrowser',
    'com.android.browser',
    'com.heytap.browser',
    'com.vivo.browser',
    'com.huawei.browser',
    'com.mi.globalbrowser',
    'com.tencent.mtt',
    'com.UCMobile',
    'com.quark.browser',
    'com.ssrvpn.android',
  };

  static const String assetPrefix =
      'packages/ssrvpn_shared/assets/rules/latest';
  static const String installedManifestFileName =
      'ssrvpn-smart-rules-manifest.json';
  static const String bundlesDirectoryName = 'bundles';
  static const int maxProviderBytes = 4 * 1024 * 1024;
  static const int maxManifestBytes = 64 * 1024;
  static const int maxVersionDescriptorBytes = 4 * 1024;
  static final RegExp _safeFileName = RegExp(r'^[a-z][a-z0-9_]*\.yaml$');
  static final RegExp _semanticVersion = RegExp(
      r'^(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})$');
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _domainAnchor = RegExp(r'[a-z0-9]');
  static final RegExp _domainRule =
      RegExp(r'^(?:\+\.)?[a-z0-9_*?][a-z0-9._*?+-]*$');

  static String providerPathPrefix(String version) {
    if (!_semanticVersion.hasMatch(version)) {
      throw ArgumentError.value(version, 'version', '规则版本号无效');
    }
    return './providers/$bundlesDirectoryName/$version';
  }

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

    final components = <String, String>{};
    final rawComponents = decoded['componentVersions'];
    if (rawComponents != null) {
      if (rawComponents is! Map ||
          rawComponents.length != 3 ||
          !rawComponents.keys
              .toSet()
              .containsAll({'rules', 'directApps', 'proxyApps'})) {
        throw const FormatException('规则组件版本集合无效');
      }
      for (final entry in rawComponents.entries) {
        if (entry.value is! String ||
            !_semanticVersion.hasMatch(entry.value as String)) {
          throw const FormatException('规则组件版本无效');
        }
        components[entry.key as String] = entry.value as String;
      }
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
          (behavior != 'domain' &&
              behavior != 'ipcidr' &&
              behavior != 'packages') ||
          count is! int ||
          count < 0 ||
          (count == 0 && behavior != 'packages') ||
          count > 200000 ||
          expectedHash is! String ||
          !_sha256.hasMatch(expectedHash)) {
        throw const FormatException('智能规则文件清单字段无效');
      }
      if ((androidFiles.contains(name) && behavior != 'packages') ||
          (!androidFiles.contains(name) && behavior == 'packages') ||
          (name == 'company_asn.yaml' && behavior != 'ipcidr') ||
          (!androidFiles.contains(name) &&
              name != 'company_asn.yaml' &&
              behavior != 'domain')) {
        throw const FormatException('规则文件用途不匹配');
      }
      files[name] = SmartRuleManifestEntry(
        name: name,
        behavior: behavior as String,
        count: count,
        sha256: expectedHash,
      );
    }
    // Desktop validates the signed manifest but never downloads Android lists.
    if (expectedFileNames != null &&
        !expectedFileNames.any(androidFiles.contains)) {
      files.removeWhere((name, _) => androidFiles.contains(name));
    }
    if (expectedFileNames != null &&
        (files.length != expectedFileNames.length ||
            !files.keys.every(expectedFileNames.contains))) {
      throw const FormatException('智能规则文件集合不完整或包含未知文件');
    }
    return SmartRuleManifest(
        version: version, files: files, componentVersions: components);
  }

  static Future<SmartRuleBundleInstallResult> ensureInstalled(
    String configDir, {
    AssetBundle? assetBundle,
    Future<bool> Function(String version)? acceptsBundledVersion,
  }) async {
    final bundle = assetBundle ?? rootBundle;
    final manifestText = await bundle.loadString('$assetPrefix/manifest.json');
    final bundledManifest = parseManifest(manifestText);
    final names = bundledManifest.files.keys
        .where((name) => Platform.isAndroid || !androidFiles.contains(name))
        .toSet();
    final manifest = parseManifest(manifestText, expectedFileNames: names);

    await _providersDirectory(configDir).create(recursive: true);
    final expectedFileNames = manifest.files.keys.toSet();
    final existing = await readInstalledManifest(
      configDir,
      expectedFileNames: expectedFileNames,
    );
    final bundledVersionAllowed =
        await acceptsBundledVersion?.call(manifest.version) ?? true;
    if (existing != null &&
        (_compareVersions(existing.version, manifest.version) >= 0 ||
            !bundledVersionAllowed)) {
      final existingDirectory = await Isolate.run(
        () => _matchingProviderDirectory(configDir, existing),
      );
      if (existingDirectory != null) {
        final versionDirectory = _bundleDirectory(configDir, existing.version);
        if (versionDirectory.path == existingDirectory.path ||
            await _copyCompleteBundle(
              existingDirectory,
              versionDirectory,
              existing,
            )) {
          return SmartRuleBundleInstallResult(
            version: manifest.version,
            activeVersion: existing.version,
            providerPathPrefix: providerPathPrefix(existing.version),
            installedFiles: versionDirectory.path == existingDirectory.path
                ? 0
                : existing.files.length,
            reusedFiles: versionDirectory.path == existingDirectory.path
                ? existing.files.length
                : 0,
          );
        }

        // A legacy complete bundle is still safer than a remote dependency if
        // migration cannot be persisted on this launch.
        return SmartRuleBundleInstallResult(
          version: manifest.version,
          activeVersion: existing.version,
          providerPathPrefix: './providers',
          installedFiles: 0,
          reusedFiles: existing.files.length,
        );
      }
    }

    if (!bundledVersionAllowed) {
      throw const FormatException('内置规则版本已被本机拒绝，且没有完整可用的旧规则');
    }
    final providersDir = _bundleDirectory(configDir, manifest.version);
    await providersDir.create(recursive: true);
    var installed = 0;
    var reused = 0;

    for (final entry in manifest.files.values) {
      final destination = File(
        '${providersDir.path}${Platform.pathSeparator}${entry.name}',
      );
      if (await Isolate.run(() => _isValidProviderFile(
            destination,
            entry.behavior,
            expectedCount: entry.count,
            expectedHash: entry.sha256,
          ))) {
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
      if (!await Isolate.run(() => _isValidProviderBytes(
            bytes,
            entry.behavior,
            expectedCount: entry.count,
          ))) {
        throw FormatException('内置智能规则内容无效: ${entry.name}');
      }
      await _replaceFile(destination, bytes);
      installed++;
    }

    if (!await activateInstalledManifest(
      configDir,
      manifestText,
      expectedFileNames: expectedFileNames,
    )) {
      throw const FormatException('内置智能规则未能完整激活');
    }

    return SmartRuleBundleInstallResult(
      version: manifest.version,
      activeVersion: manifest.version,
      providerPathPrefix: providerPathPrefix(manifest.version),
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
  }) =>
      Isolate.run(() => _readInstalledManifest(configDir,
          expectedFileNames: expectedFileNames));

  static Future<SmartRuleManifest?> _readInstalledManifest(
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
      return await _matchingProviderDirectory(configDir, manifest) == null
          ? null
          : manifest;
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
  }) =>
      Isolate.run(() => _activateInstalledManifest(configDir, manifestText,
          expectedFileNames: expectedFileNames));

  static Future<bool> _activateInstalledManifest(
    String configDir,
    String manifestText, {
    required Set<String> expectedFileNames,
  }) async {
    final manifest = parseManifest(
      manifestText,
      expectedFileNames: expectedFileNames,
    );
    if (!await _matchesProviderDirectory(
      _bundleDirectory(configDir, manifest.version),
      manifest,
    )) {
      // Backward-compatible activation of the pre-versioned layout. Startup
      // migrates this complete legacy set before generating a local config.
      if (!await _matchesProviderDirectory(
        _providersDirectory(configDir),
        manifest,
      )) {
        return false;
      }
    }
    await _replaceFile(
        _installedManifest(configDir), utf8.encode(manifestText));
    return true;
  }

  static bool providerContentsMatch(
    SmartRuleManifest manifest,
    Map<String, String> providerContents,
  ) {
    for (final entry in providerContents.entries) {
      final expected = manifest.files[entry.key];
      if (expected == null) return false;
      final bytes = utf8.encode(entry.value);
      if (bytes.isEmpty ||
          bytes.length > maxProviderBytes ||
          crypto.sha256.convert(bytes).toString() != expected.sha256 ||
          !_isValidProviderBytes(
            bytes,
            expected.behavior,
            expectedCount: expected.count,
          )) {
        return false;
      }
    }
    return true;
  }

  /// Stages a complete version without touching the active manifest or files.
  /// Unchanged providers are copied from the currently active complete bundle.
  /// The caller may activate the new version only after this returns true.
  static Future<bool> installVerifiedProviderFiles(
    String configDir,
    SmartRuleManifest manifest,
    Map<String, String> providerContents,
  ) =>
      Isolate.run(() =>
          _installVerifiedProviderFiles(configDir, manifest, providerContents));

  static Future<bool> _installVerifiedProviderFiles(
    String configDir,
    SmartRuleManifest manifest,
    Map<String, String> providerContents,
  ) async {
    if (!providerContentsMatch(manifest, providerContents)) return false;
    final activeManifest = await _readInstalledManifest(
      configDir,
      expectedFileNames: manifest.files.keys.toSet(),
    );
    final sourceDirectory = activeManifest == null
        ? null
        : await _matchingProviderDirectory(configDir, activeManifest);
    final targetDirectory = _bundleDirectory(configDir, manifest.version);
    await targetDirectory.create(recursive: true);

    for (final entry in manifest.files.values) {
      final destination = File(
        '${targetDirectory.path}${Platform.pathSeparator}${entry.name}',
      );
      if (await Isolate.run(() => _isValidProviderFile(
            destination,
            entry.behavior,
            expectedCount: entry.count,
            expectedHash: entry.sha256,
          ))) {
        continue;
      }
      final downloaded = providerContents[entry.name];
      if (downloaded != null) {
        await _replaceFile(destination, utf8.encode(downloaded));
        continue;
      }
      if (sourceDirectory == null) return false;
      final source = File(
        '${sourceDirectory.path}${Platform.pathSeparator}${entry.name}',
      );
      if (!await _isValidProviderFile(
        source,
        entry.behavior,
        expectedCount: entry.count,
        expectedHash: entry.sha256,
      )) {
        return false;
      }
      await _replaceFile(destination, await source.readAsBytes());
    }
    return _matchesProviderDirectory(targetDirectory, manifest);
  }

  static File _installedManifest(String configDir) => File(
        '$configDir${Platform.pathSeparator}providers'
        '${Platform.pathSeparator}$installedManifestFileName',
      );

  static Directory _providersDirectory(String configDir) => Directory(
        '$configDir${Platform.pathSeparator}providers',
      );

  static Directory _bundleDirectory(String configDir, String version) =>
      Directory(
        '${_providersDirectory(configDir).path}${Platform.pathSeparator}'
        '$bundlesDirectoryName${Platform.pathSeparator}$version',
      );

  static Future<Directory?> _matchingProviderDirectory(
    String configDir,
    SmartRuleManifest manifest,
  ) async {
    final versionDirectory = _bundleDirectory(configDir, manifest.version);
    if (await _matchesProviderDirectory(versionDirectory, manifest)) {
      return versionDirectory;
    }
    final legacyDirectory = _providersDirectory(configDir);
    if (await _matchesProviderDirectory(legacyDirectory, manifest)) {
      return legacyDirectory;
    }
    return null;
  }

  static Future<bool> _copyCompleteBundle(
    Directory source,
    Directory destination,
    SmartRuleManifest manifest,
  ) async {
    try {
      await destination.create(recursive: true);
      for (final entry in manifest.files.values) {
        final sourceFile = File(
          '${source.path}${Platform.pathSeparator}${entry.name}',
        );
        final destinationFile = File(
          '${destination.path}${Platform.pathSeparator}${entry.name}',
        );
        if (await _isValidProviderFile(
          destinationFile,
          entry.behavior,
          expectedCount: entry.count,
          expectedHash: entry.sha256,
        )) {
          continue;
        }
        await _replaceFile(destinationFile, await sourceFile.readAsBytes());
      }
      return _matchesProviderDirectory(destination, manifest);
    } on Object {
      return false;
    }
  }

  static Future<bool> _matchesProviderDirectory(
    Directory directory,
    SmartRuleManifest manifest,
  ) async {
    for (final entry in manifest.files.values) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}${entry.name}',
      );
      if (!await _isValidProviderFile(
        file,
        entry.behavior,
        expectedCount: entry.count,
        expectedHash: entry.sha256,
      )) {
        return false;
      }
    }
    if (manifest.files.keys.toSet().containsAll(androidFiles)) {
      try {
        await _readAndroidRules(directory);
      } on Object {
        return false;
      }
    }
    return true;
  }

  static Future<bool> verifyVersion(
          String configDir, SmartRuleManifest manifest) =>
      Isolate.run(() => _matchesProviderDirectory(
          _bundleDirectory(configDir, manifest.version), manifest));

  static Future<List<String>> androidRules(String configDir, String version) =>
      Isolate.run(
          () => _readAndroidRules(_bundleDirectory(configDir, version)));

  static Future<List<String>> _readAndroidRules(Directory directory) async {
    final rules = <String>[];
    final packages = <String>{};
    for (final name in androidFiles) {
      final file = File('${directory.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > maxProviderBytes) {
        throw const FormatException('应用名单文件无效');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxProviderBytes ||
          !_isValidProviderBytes(bytes, 'packages')) {
        throw const FormatException('应用名单内容无效');
      }
      final document =
          BoundedYaml.load(utf8.decode(bytes), collectionLimit: 200010) as Map;
      final target = name == 'direct_apps.yaml' ? 'DIRECT' : 'PROXY';
      for (final package in document['payload'] as List) {
        if (!packages.add(package as String)) {
          throw const FormatException('应用名单冲突');
        }
        rules.add('PROCESS-NAME,$package,$target');
      }
    }
    return rules;
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
      final yaml = BoundedYaml.load(decoded, collectionLimit: 200010);
      if (yaml is! YamlMap || yaml.length != 1) return false;
      final payload = yaml['payload'];
      if (payload is! YamlList ||
          (payload.isEmpty && behavior != 'packages') ||
          payload.length > 200000 ||
          (expectedCount != null && payload.length != expectedCount)) {
        return false;
      }
      final seen = <String>{};
      for (final value in payload) {
        if (value is! String || value.isEmpty || !seen.add(value)) return false;
        if (behavior == 'packages') {
          if (!packageNamePattern.hasMatch(value) ||
              excludedPackages.contains(value) ||
              value.length > 255) {
            return false;
          }
        } else if (behavior == 'domain') {
          if (value != value.toLowerCase() ||
              !_domainRule.hasMatch(value) ||
              !_domainAnchor.hasMatch(value) ||
              {'*', '+.*', '+.com', '+.net', '+.org'}.contains(value)) {
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
    return prefix > 0 && prefix <= maxPrefix;
  }

  static int _compareVersions(String left, String right) {
    final leftParts = left.split('.').map(int.parse).toList(growable: false);
    final rightParts = right.split('.').map(int.parse).toList(growable: false);
    for (var index = 0; index < leftParts.length; index++) {
      final comparison = leftParts[index].compareTo(rightParts[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
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
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw const FileSystemException('规则目标不是普通文件');
      }
      // Rename replaces a regular destination; never delete the only good copy first.
      await temp.rename(destination.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}

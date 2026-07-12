import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.changelog,
    this.sha256,
    this.sourceHost,
    this.fallbackDownloadUrl,
  });

  final String version;
  final String downloadUrl;
  final String changelog;
  final String? sha256;
  final String? sourceHost;
  final String? fallbackDownloadUrl;
}

class _ReleaseAsset {
  const _ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    this.sha256,
  });

  final String name;
  final String downloadUrl;
  final String? sha256;
}

class UpdateChecker {
  static const String owner = 'Elegying';
  static const String repo = 'SSRVPN';
  static final Uri primaryManifestUrl = Uri.parse(
    'https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/latest.json',
  );
  static final Uri githubLatestReleaseUrl = Uri.parse(
    'https://api.github.com/repos/$owner/$repo/releases/latest',
  );

  static Future<AppUpdateInfo?> checkLatest({
    required String currentVersion,
    required String assetExtension,
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final primary = await _checkPrimaryManifest(
        currentVersion: currentVersion,
        assetExtension: assetExtension,
        client: httpClient,
        timeout: timeout,
      );
      if (primary != null) return primary;

      return await _checkGitHub(
        currentVersion: currentVersion,
        assetExtension: assetExtension,
        client: httpClient,
        timeout: timeout,
      );
    } catch (_) {
      return null;
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  static Future<AppUpdateInfo?> _checkPrimaryManifest({
    required String currentVersion,
    required String assetExtension,
    required http.Client client,
    required Duration timeout,
  }) async {
    try {
      final response = await client.get(
        primaryManifestUrl,
        headers: {
          'Accept': 'application/json',
          'User-Agent': AppConstants.appUserAgent,
        },
      ).timeout(timeout);
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return null;

      final version = (data['version']?.toString() ?? '')
          .trim()
          .replaceFirst(RegExp(r'^v'), '');
      if (!_isValidVersion(version)) return null;
      // A stale pointer can remain when GitHub publishing succeeds but the OSS
      // upload fails. Let GitHub act as the backup detector in that case.
      if (compareVersions(version, currentVersion) <= 0) return null;

      final asset = _manifestAssetFor(
        data['assets'],
        assetExtension,
        version,
      );
      if (asset == null) return null;
      final sourceHost = Uri.parse(asset.downloadUrl).host;
      final fallbackUrl = Uri.https(
        'github.com',
        '/$owner/$repo/releases/download/v$version/${asset.name}',
      ).toString();

      return AppUpdateInfo(
        version: version,
        downloadUrl: asset.downloadUrl,
        fallbackDownloadUrl: fallbackUrl,
        changelog: _buildChangelog(
          data['changelog']?.toString() ?? '',
          sourceHost: sourceHost,
          sha256: asset.sha256,
        ),
        sha256: asset.sha256,
        sourceHost: sourceHost,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<AppUpdateInfo?> _checkGitHub({
    required String currentVersion,
    required String assetExtension,
    required http.Client client,
    required Duration timeout,
  }) async {
    try {
      final response = await client.get(
        githubLatestReleaseUrl,
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': AppConstants.appUserAgent,
        },
      ).timeout(timeout);

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return null;

      final latestVersion = (data['tag_name']?.toString() ?? '').replaceFirst(
        RegExp(r'^v'),
        '',
      );
      if (!_isValidVersion(latestVersion)) return null;
      if (compareVersions(latestVersion, currentVersion) <= 0) return null;

      final releaseAssets = _releaseAssets(data['assets']);
      final selectedAsset = _assetFor(releaseAssets, assetExtension);
      if (selectedAsset == null) return null;
      final downloadUrl = selectedAsset.downloadUrl;
      if (!_isExpectedGitHubAssetUrl(
        downloadUrl,
        version: latestVersion,
        assetName: selectedAsset.name,
      )) {
        return null;
      }
      final sha256 = await _sha256ForAsset(
        releaseAssets,
        selectedAsset,
        latestVersion,
        client,
        timeout,
      );
      if (sha256 == null) return null;
      final sourceHost = Uri.parse(downloadUrl).host;

      return AppUpdateInfo(
        version: latestVersion,
        downloadUrl: downloadUrl,
        changelog: _buildChangelog(
          data['body']?.toString() ?? '',
          sourceHost: sourceHost,
          sha256: sha256,
        ),
        sha256: sha256,
        sourceHost: sourceHost,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _isValidVersion(String version) =>
      RegExp(r'^\d+(?:\.\d+){1,3}$').hasMatch(version);

  static _ReleaseAsset? _manifestAssetFor(
    Object? assets,
    String assetExtension,
    String version,
  ) {
    if (assets is! List) return null;
    final wantedName = _assetNameForExtension(assetExtension);
    if (wantedName == null) return null;
    final expectedPath = '/ssrvpn/releases/v$version/$wantedName';
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name']?.toString() ?? '';
      final downloadUrl = asset['url']?.toString() ?? '';
      final sha256 = asset['sha256']?.toString().trim().toLowerCase() ?? '';
      final uri = Uri.tryParse(downloadUrl);
      if (name == wantedName &&
          uri != null &&
          uri.scheme == 'https' &&
          uri.host == primaryManifestUrl.host &&
          uri.userInfo.isEmpty &&
          !uri.hasPort &&
          uri.path == expectedPath &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
        return _ReleaseAsset(
          name: name,
          downloadUrl: downloadUrl,
          sha256: sha256,
        );
      }
    }
    return null;
  }

  static int compareVersions(String a, String b) {
    final aParts = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final bParts = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final ai = i < aParts.length ? aParts[i] : 0;
      final bi = i < bParts.length ? bParts[i] : 0;
      if (ai > bi) return 1;
      if (ai < bi) return -1;
    }
    return 0;
  }

  static List<_ReleaseAsset> _releaseAssets(Object? assets) {
    if (assets is! List) return const [];
    final result = <_ReleaseAsset>[];
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name']?.toString();
      final candidate = asset['browser_download_url']?.toString();
      if (name != null &&
          name.isNotEmpty &&
          candidate != null &&
          _isSecureDownloadUrl(candidate)) {
        result.add(_ReleaseAsset(name: name, downloadUrl: candidate));
      }
    }
    return result;
  }

  static _ReleaseAsset? _assetFor(
    List<_ReleaseAsset> assets,
    String assetExtension,
  ) {
    final wantedName = _assetNameForExtension(assetExtension);
    if (wantedName == null) return null;
    for (final asset in assets) {
      if (asset.name == wantedName) return asset;
    }
    return null;
  }

  static String? _assetNameForExtension(String assetExtension) {
    return switch (assetExtension.trim().toLowerCase()) {
      '.apk' => 'SSRVPN.apk',
      '.dmg' => 'SSRVPN.dmg',
      '.exe' => 'SSRVPN_Setup.exe',
      '.zip' => 'SSRVPN.zip',
      _ => null,
    };
  }

  static bool _isSecureDownloadUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  static Future<String?> _sha256ForAsset(
    List<_ReleaseAsset> assets,
    _ReleaseAsset asset,
    String version,
    http.Client client,
    Duration timeout,
  ) async {
    final checksumName = '${asset.name}.sha256'.toLowerCase();
    _ReleaseAsset? checksumAsset;
    for (final candidate in assets) {
      if (candidate.name.toLowerCase() == checksumName) {
        checksumAsset = candidate;
        break;
      }
    }
    if (checksumAsset == null) return null;
    if (!_isExpectedGitHubAssetUrl(
      checksumAsset.downloadUrl,
      version: version,
      assetName: checksumAsset.name,
    )) {
      return null;
    }

    try {
      final response = await client
          .get(Uri.parse(checksumAsset.downloadUrl))
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      final checksumLine = RegExp(
        '^\\s*([a-fA-F0-9]{64})\\s+\\*?${RegExp.escape(asset.name)}\\s*\$',
        multiLine: true,
      ).firstMatch(response.body);
      return checksumLine?.group(1)?.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static bool _isExpectedGitHubAssetUrl(
    String value, {
    required String version,
    required String assetName,
  }) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.path == '/$owner/$repo/releases/download/v$version/$assetName';
  }

  static String _buildChangelog(
    String body, {
    required String? sourceHost,
    required String? sha256,
  }) {
    final lines = <String>[];
    final trimmedBody = _normalizeReleaseNotes(body.trim());
    if (trimmedBody.isNotEmpty) lines.add(trimmedBody);
    if (sourceHost != null && sourceHost.isNotEmpty) {
      lines.add('下载来源: $sourceHost');
    }
    if (sha256 != null && sha256.isNotEmpty) {
      lines.add('SHA256: $sha256');
    }
    return lines.join('\n\n');
  }

  static String _normalizeReleaseNotes(String body) {
    if (body.isEmpty) return body;
    final replacements = <String, String>{
      '### Downloads': '### 下载',
      '### Added': '### 新增',
      '### Changed': '### 变更',
      '### Deprecated': '### 废弃',
      '### Removed': '### 移除',
      '### Fixed': '### 修复',
      '### Security': '### 安全',
      '| Platform | File | Checksum |': '| 平台 | 文件 | 校验和 |',
      'Verify checksums:': '校验 SHA256：',
    };
    var normalized = body;
    for (final entry in replacements.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }
    return normalized;
  }
}

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
  });

  final String version;
  final String downloadUrl;
  final String changelog;
  final String? sha256;
  final String? sourceHost;
}

class _ReleaseAsset {
  const _ReleaseAsset({required this.name, required this.downloadUrl});

  final String name;
  final String downloadUrl;
}

class UpdateChecker {
  static const String owner = 'Elegying';
  static const String repo = 'SSRVPN';

  static Future<AppUpdateInfo?> checkLatest({
    required String currentVersion,
    required String assetExtension,
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final url = Uri.parse(
        'https://api.github.com/repos/$owner/$repo/releases/latest',
      );
      final response = await httpClient.get(
        url,
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
      if (compareVersions(latestVersion, currentVersion) <= 0) return null;

      final releaseAssets = _releaseAssets(data['assets']);
      final selectedAsset = _assetFor(releaseAssets, assetExtension) ??
          (releaseAssets.isEmpty ? null : releaseAssets.first);
      final downloadUrl =
          selectedAsset?.downloadUrl ?? data['html_url']?.toString();
      if (downloadUrl == null || downloadUrl.isEmpty) return null;
      final sha256 = selectedAsset == null
          ? null
          : await _sha256ForAsset(
              releaseAssets,
              selectedAsset,
              httpClient,
              timeout,
            );
      final sourceHost = Uri.tryParse(downloadUrl)?.host;

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
    } finally {
      if (ownsClient) httpClient.close();
    }
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
          candidate.isNotEmpty) {
        result.add(_ReleaseAsset(name: name, downloadUrl: candidate));
      }
    }
    return result;
  }

  static _ReleaseAsset? _assetFor(
    List<_ReleaseAsset> assets,
    String assetExtension,
  ) {
    final wanted = assetExtension.toLowerCase();
    for (final asset in assets) {
      if (asset.name.toLowerCase().endsWith(wanted)) return asset;
    }
    return null;
  }

  static Future<String?> _sha256ForAsset(
    List<_ReleaseAsset> assets,
    _ReleaseAsset asset,
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

    try {
      final response = await client
          .get(Uri.parse(checksumAsset.downloadUrl))
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return RegExp(
        r'\b[a-fA-F0-9]{64}\b',
      ).firstMatch(response.body)?.group(0)?.toLowerCase();
    } catch (_) {
      return null;
    }
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

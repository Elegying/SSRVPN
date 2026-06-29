import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme/app_theme.dart';

/// 在线更新服务 - 基于 GitHub Releases
class UpdateService {
  static const String appVersion = '2.0.0';
  static const String _owner = 'Elegying';
  static const String _repo = 'SSRVPN_Windows';

  /// 检查是否有新版本
  static Future<(String, String, String)?> checkForUpdate(
      String currentVersion) async {
    try {
      final url = Uri.parse(
          'https://api.github.com/repos/$_owner/$_repo/releases/latest');
      final response = await http.get(url, headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'SSRVPN-UpdateChecker',
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode == 403) {
        debugPrint('[更新] GitHub API rate limit，请稍后再试');
        return null;
      }
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      final tagName = data['tag_name'] as String? ?? '';
      final body = data['body'] as String? ?? '';
      final assets = data['assets'] as List? ?? [];

      final latestVersion = tagName.replaceFirst('v', '');
      if (_compareVersions(latestVersion, currentVersion) <= 0) return null;

      String? downloadUrl;
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name']?.toString().toLowerCase() ?? '';
        final candidate = asset['browser_download_url']?.toString();
        if (name.endsWith('.zip') && candidate != null) {
          downloadUrl = candidate;
          break;
        }
      }

      downloadUrl ??= assets.isNotEmpty
          ? ((assets.first as Map?)?['browser_download_url']?.toString())
          : data['html_url']?.toString();

      if (downloadUrl == null) return null;
      return (latestVersion, downloadUrl, body);
    } catch (e) {
      debugPrint('[更新] 检查更新失败: $e');
      return null;
    }
  }

  static int _compareVersions(String a, String b) {
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

  /// 打开下载链接
  static Future<void> openDownload(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
        throw const FormatException('Invalid download URL');
      }
      await Process.start('explorer.exe', [url]);
    } catch (e) {
      debugPrint('[更新] 打开链接失败: $e');
    }
  }

  /// 显示更新弹窗
  static void showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    required String changelog,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.primary, AppTheme.accentColor],
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.system_update_rounded,
                    size: 28, color: Colors.white),
              ),
              const SizedBox(height: 16),
              Text(
                '发现新版本',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppTheme.textPrimary
                      : AppTheme.lightTextPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'v$currentVersion → v$latestVersion',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (changelog.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 5 / 255)
                        : Colors.black.withValues(alpha: 5 / 255),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      changelog,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: isDark
                            ? AppTheme.textSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text('稍后再说',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark
                                ? AppTheme.textSecondary
                                : AppTheme.lightTextSecondary,
                          )),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        openDownload(downloadUrl);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                      child: const Text('立即更新',
                          style: TextStyle(fontSize: 14, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

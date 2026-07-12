import 'package:flutter/material.dart';

import 'update_checker.dart';

typedef DownloadOpener = Future<void> Function(String url);

class SharedUpdateService {
  static Future<(String, String, String, String?)?> checkForUpdate({
    required String currentVersion,
    required String assetExtension,
  }) async {
    final update = await UpdateChecker.checkLatest(
      currentVersion: currentVersion,
      assetExtension: assetExtension,
    );
    if (update == null) return null;
    return (
      update.version,
      update.downloadUrl,
      update.changelog,
      update.fallbackDownloadUrl,
    );
  }

  static Uri validateDownloadUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('Invalid download URL');
    }
    return uri;
  }

  static void showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    String? fallbackDownloadUrl,
    required String changelog,
    required Color primaryColor,
    required Color accentColor,
    required Color textPrimary,
    required Color textSecondary,
    required Color lightTextPrimary,
    required Color lightTextSecondary,
    required DownloadOpener openDownload,
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
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor, accentColor],
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.system_update_rounded,
                  size: 28,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '发现新版本',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: isDark ? textPrimary : lightTextPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'v$currentVersion → v$latestVersion',
                style: TextStyle(
                  fontSize: 13,
                  color: primaryColor,
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
                        color: isDark ? textSecondary : lightTextSecondary,
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
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        '稍后再说',
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark ? textSecondary : lightTextSecondary,
                        ),
                      ),
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
                        backgroundColor: primaryColor,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        '立即更新',
                        style: TextStyle(fontSize: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
              if (fallbackDownloadUrl != null &&
                  fallbackDownloadUrl.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openDownload(fallbackDownloadUrl);
                  },
                  child: const Text('OSS 下载异常？使用 GitHub 备用下载'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

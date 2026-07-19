import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';

/// 在线更新服务 - OSS 主源，GitHub Releases 备用。
class UpdateService {
  static const String appVersion = AppConstants.appVersion;
  static const String _openPath = '/usr/bin/open';

  static Future<AppUpdateInfo?> checkForUpdate(
    String currentVersion,
  ) {
    return SharedUpdateService.checkForUpdate(
      currentVersion: currentVersion,
      assetExtension: '.dmg',
    );
  }

  static Future<void> openExternalUrl(String url) async {
    try {
      final uri = SharedUpdateService.validateDownloadUrl(url);
      await Process.start(_openPath, [uri.toString()]);
    } catch (e) {
      AppLogger.warning('Update', '打开链接失败: $e');
    }
  }

  static Future<void> openDownload(String url) => openExternalUrl(url);

  static Future<void> showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    required String changelog,
    required String? sha256,
    String? fallbackDownloadUrl,
  }) async {
    final update = AppUpdateInfo(
      version: latestVersion,
      downloadUrl: downloadUrl,
      fallbackDownloadUrl: fallbackDownloadUrl,
      changelog: changelog,
      sha256: sha256,
    );
    await AppModalCoordinator.run<void>(() async {
      if (!context.mounted) return;
      final isDark = Theme.of(context).brightness == Brightness.dark;

      Future<void> downloadAndOpen(String url) =>
          SharedUpdateService.downloadAndOpenVerifiedUpdate(
            context,
            SharedUpdateService.preferDownloadUrl(update, url),
            fileName: 'SSRVPN.dmg',
            openFile: (file) async {
              await Process.start(_openPath, [file.path]);
            },
          );

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
          title: const Text('发现新版本'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'v$currentVersion → v$latestVersion',
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '下载并校验完成后会打开 DMG。请将 SSRVPN 拖入“应用程序”文件夹，替换旧版本，然后重新启动 SSRVPN。',
                  ),
                  if (changelog.trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      changelog,
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.textSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('稍后再说'),
            ),
            if (fallbackDownloadUrl != null &&
                fallbackDownloadUrl.trim().isNotEmpty)
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  unawaited(downloadAndOpen(fallbackDownloadUrl));
                },
                child: const Text('使用 GitHub 备用下载'),
              ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(downloadAndOpen(downloadUrl));
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('下载并打开 DMG'),
            ),
          ],
        ),
      );
    });
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';
import 'windows_desktop_directory.dart';

/// 在线更新服务 - OSS 主源，GitHub Releases 备用。
class UpdateService {
  static const String appVersion = AppConstants.appVersion;

  static Future<AppUpdateInfo?> checkForUpdate(
    String currentVersion,
  ) {
    return SharedUpdateService.checkForUpdate(
      currentVersion: currentVersion,
      assetExtension: '.exe',
    );
  }

  static Future<void> showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    required String changelog,
    required String? sha256,
    String? fallbackDownloadUrl,
    Directory? desktopDirectory,
    http.Client? client,
  }) async {
    final update = AppUpdateInfo(
      version: latestVersion,
      downloadUrl: downloadUrl,
      fallbackDownloadUrl: fallbackDownloadUrl,
      changelog: changelog,
      sha256: sha256,
    );
    await SharedUpdateService.showUpdateDialog(
      context,
      latestVersion: latestVersion,
      currentVersion: currentVersion,
      downloadUrl: downloadUrl,
      fallbackDownloadUrl: fallbackDownloadUrl,
      changelog: changelog,
      primaryColor: AppTheme.primary,
      accentColor: AppTheme.accentColor,
      textPrimary: AppTheme.textPrimary,
      textSecondary: AppTheme.textSecondary,
      lightTextPrimary: AppTheme.lightTextPrimary,
      lightTextSecondary: AppTheme.lightTextSecondary,
      primaryActionLabel: '下载到桌面',
      openDownload: (url) => downloadUpdateToDesktop(
        context,
        SharedUpdateService.preferDownloadUrl(update, url),
        desktopDirectory: desktopDirectory,
        client: client,
      ),
    );
  }

  static Future<void> downloadUpdateToDesktop(
    BuildContext context,
    AppUpdateInfo update, {
    Directory? desktopDirectory,
    http.Client? client,
  }) async {
    late final Directory desktop;
    try {
      desktop = desktopDirectory ?? WindowsDesktopDirectory.resolve();
    } catch (error) {
      await _showDesktopResolutionFailure(context, error);
      return;
    }
    if (!context.mounted) return;

    await recoverStaleDesktopArtifacts(desktop);
    if (!context.mounted) return;

    await SharedUpdateService.downloadVerifiedUpdateWithProgress(
      context,
      update,
      outputDirectory: desktop,
      fileName: _installerFileName(update.version),
      client: client,
      progressDescription: '下载完成并通过 SHA256 校验后会保存到桌面，不会自动启动安装程序。',
      onVerified: (file) => _showDesktopDownloadComplete(context, file),
    );
  }

  static String _installerFileName(String version) {
    final normalized = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final safeVersion = normalized.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    return safeVersion.isEmpty
        ? 'SSRVPN_Setup.exe'
        : 'SSRVPN_Setup_v$safeVersion.exe';
  }

  @visibleForTesting
  static Future<void> recoverStaleDesktopArtifacts(
    Directory desktop, {
    DateTime? now,
    Duration staleAfter = const Duration(days: 1),
  }) async {
    final cutoff = (now ?? DateTime.now()).subtract(staleAfter);
    final artifactPattern = RegExp(
      r'^(SSRVPN_Setup(?:_v[A-Za-z0-9._-]+)?\.exe)\.(part|previous)\.'
      r'\d+_\d+_\d+$',
    );
    try {
      await for (final entity in desktop.list(followLinks: false)) {
        try {
          if (entity is! File ||
              await FileSystemEntity.type(entity.path, followLinks: false) !=
                  FileSystemEntityType.file) {
            continue;
          }
          final match = artifactPattern.firstMatch(p.basename(entity.path));
          if (match == null ||
              !(await entity.stat()).modified.isBefore(cutoff)) {
            continue;
          }
          if (match.group(2) == 'previous') {
            final destination = File(p.join(desktop.path, match.group(1)!));
            final destinationType = await FileSystemEntity.type(
              destination.path,
              followLinks: false,
            );
            if (destinationType == FileSystemEntityType.notFound) {
              await entity.rename(destination.path);
            } else if (destinationType == FileSystemEntityType.file) {
              await entity.delete();
            }
          } else {
            await entity.delete();
          }
        } catch (_) {
          // Cleanup is best-effort; update download and verification remain
          // authoritative even when an artifact is locked by another process.
        }
      }
    } catch (_) {}
  }

  static Future<void> _showDesktopDownloadComplete(
    BuildContext context,
    File file,
  ) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('最新版安装包已下载到桌面，请直接安装'),
            const SizedBox(height: 8),
            SelectableText(
              file.path,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static Future<void> _showDesktopResolutionFailure(
    BuildContext context,
    Object error,
  ) {
    return AppModalCoordinator.run<void>(() async {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('更新失败'),
          content: Text(error.toString().replaceFirst('Bad state: ', '')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    });
  }
}

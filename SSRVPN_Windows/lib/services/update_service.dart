import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';
import 'windows_detached_installer_launcher.dart';

/// 在线更新服务 - OSS 主源，GitHub Releases 备用。
class UpdateService {
  static const String appVersion = AppConstants.appVersion;
  static Future<bool> Function()? onInstallerHandoff;

  static Future<AppUpdateInfo?> checkForUpdate(
    String currentVersion,
  ) {
    return SharedUpdateService.checkForUpdate(
      currentVersion: currentVersion,
      assetExtension: '.exe',
    );
  }

  static Future<void> openExternalUrl(String url) async {
    try {
      final uri = SharedUpdateService.validateDownloadUrl(url);
      await Process.start('explorer.exe', [uri.toString()]);
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
      openDownload: (_) => SharedUpdateService.downloadAndOpenVerifiedUpdate(
        context,
        update,
        fileName: 'SSRVPN_Setup.exe',
        openFile: installVerifiedUpdate,
      ),
    );
  }

  static Future<void> installVerifiedUpdate(
    File file, {
    Future<void> Function(File file)? launchInstaller,
    Future<bool> Function()? shutdownApp,
  }) async {
    final shutdown = shutdownApp ?? onInstallerHandoff;
    if (shutdown == null) {
      throw StateError('SSRVPN 尚未准备好安全退出，更新安装未启动');
    }
    await (launchInstaller ?? WindowsDetachedInstallerLauncher.launch)(file);
    if (!await shutdown()) {
      throw StateError('系统代理或核心清理未完成，SSRVPN 保持运行，安装已中止');
    }
  }
}

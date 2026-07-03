import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';

/// 在线更新服务 - 基于 GitHub Releases
class UpdateService {
  static const String appVersion = AppConstants.appVersion;

  static Future<(String, String, String)?> checkForUpdate(
    String currentVersion,
  ) {
    return SharedUpdateService.checkForUpdate(
      currentVersion: currentVersion,
      assetExtension: '.zip',
    );
  }

  static Future<void> openDownload(String url) async {
    try {
      final uri = SharedUpdateService.validateDownloadUrl(url);
      await Process.start('explorer.exe', [uri.toString()]);
    } catch (e) {
      AppLogger.warning('Update', '打开链接失败: $e');
    }
  }

  static void showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    required String changelog,
  }) {
    SharedUpdateService.showUpdateDialog(
      context,
      latestVersion: latestVersion,
      currentVersion: currentVersion,
      downloadUrl: downloadUrl,
      changelog: changelog,
      primaryColor: AppTheme.primary,
      accentColor: AppTheme.accentColor,
      textPrimary: AppTheme.textPrimary,
      textSecondary: AppTheme.textSecondary,
      lightTextPrimary: AppTheme.lightTextPrimary,
      lightTextSecondary: AppTheme.lightTextSecondary,
      openDownload: openDownload,
    );
  }
}

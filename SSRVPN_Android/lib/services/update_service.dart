import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';

/// 在线更新服务 - 基于 GitHub Releases
class UpdateService {
  /// 当前应用版本（发版时与 pubspec.yaml 的 version 同步修改）
  static const String appVersion = AppConstants.appVersion;

  /// Android 原生通道（openUrl 注册在 MainActivity 的 com.ssrvpn/native 上）
  static const _channel = MethodChannel('com.ssrvpn/native');

  static Future<(String, String, String)?> checkForUpdate(
    String currentVersion,
  ) {
    return SharedUpdateService.checkForUpdate(
      currentVersion: currentVersion,
      assetExtension: '.apk',
    );
  }

  static Future<void> openDownload(String url) async {
    try {
      final uri = SharedUpdateService.validateDownloadUrl(url);
      await _channel.invokeMethod('openUrl', {'url': uri.toString()});
    } catch (e) {
      debugPrint('[更新] 打开链接失败: $e');
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
      primaryColor: AppTheme.primaryColor,
      accentColor: AppTheme.accentColor,
      textPrimary: AppTheme.darkTextPrimary,
      textSecondary: AppTheme.darkTextSecondary,
      lightTextPrimary: AppTheme.lightTextPrimary,
      lightTextSecondary: AppTheme.lightTextSecondary,
      openDownload: openDownload,
    );
  }
}

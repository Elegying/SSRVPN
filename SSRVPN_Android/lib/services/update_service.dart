import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';

/// 在线更新服务 - 基于 GitHub Releases
class UpdateService {
  /// 当前应用版本（发版时与 pubspec.yaml 的 version 同步修改）
  static const String appVersion = AppConstants.appVersion;

  /// 防止异常或恶意响应耗尽设备存储与内存。
  static const int maxApkDownloadBytes = 200 * 1024 * 1024;

  /// Android 原生通道（openUrl 注册在 MainActivity 的 com.ssrvpn/native 上）
  static const _channel = MethodChannel('com.ssrvpn/native');

  static Future<AppUpdateInfo?> checkForUpdate(
    String currentVersion,
  ) {
    return UpdateChecker.checkLatest(
      currentVersion: currentVersion,
      assetExtension: '.apk',
    );
  }

  static Future<void> openExternalUrl(String url) async {
    try {
      final uri = SharedUpdateService.validateDownloadUrl(url);
      await _channel.invokeMethod('openUrl', {'url': uri.toString()});
    } catch (e) {
      AppLogger.warning('Update', '打开链接失败: $e');
    }
  }

  static Future<File> downloadUpdateApk(
    AppUpdateInfo update, {
    Directory? outputDirectory,
    http.Client? client,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final expectedSha256 = update.sha256?.trim().toLowerCase();
    if (expectedSha256 == null || expectedSha256.isEmpty) {
      throw StateError('缺少 APK SHA256 校验文件，已取消更新');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
      throw StateError('APK SHA256 校验值格式无效，已取消更新');
    }

    final downloadUris = <Uri>[
      SharedUpdateService.validateDownloadUrl(update.downloadUrl),
    ];
    final fallbackUrl = update.fallbackDownloadUrl?.trim();
    if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
      final fallbackUri = SharedUpdateService.validateDownloadUrl(fallbackUrl);
      if (fallbackUri != downloadUris.first) downloadUris.add(fallbackUri);
    }
    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    final baseDir = outputDirectory ?? await getTemporaryDirectory();
    final updateDir = Directory('${baseDir.path}/ssrvpn_update');
    if (!await updateDir.exists()) {
      await updateDir.create(recursive: true);
    }

    final apkFile = File('${updateDir.path}/SSRVPN-${update.version}.apk');
    final tempFile = File('${apkFile.path}.part');
    if (await tempFile.exists()) await tempFile.delete();
    if (await apkFile.exists()) await apkFile.delete();

    try {
      for (var attempt = 0; attempt < downloadUris.length; attempt++) {
        final uri = downloadUris[attempt];
        try {
          final request = http.Request('GET', uri)
            ..headers['User-Agent'] = AppConstants.appUserAgent;
          final response = await httpClient.send(request).timeout(timeout);
          if (response case http.BaseResponseWithUrl(:final url)) {
            if (url.scheme != 'https' || url.host.isEmpty) {
              await response.stream.listen((_) {}).cancel();
              throw const FormatException('Invalid download URL');
            }
          }
          if (response.statusCode != HttpStatus.ok) {
            await response.stream.listen((_) {}).cancel();
            throw StateError('下载更新失败: HTTP ${response.statusCode}');
          }

          var received = 0;
          final total = response.contentLength;
          if (total != null && total > maxApkDownloadBytes) {
            await response.stream.listen((_) {}).cancel();
            throw StateError('APK 文件过大，已取消更新');
          }
          final output = await tempFile.open(mode: FileMode.write);
          final digestSink = _DigestSink();
          final hashSink = sha256.startChunkedConversion(digestSink);
          late final String actualSha256;
          var hashClosed = false;
          try {
            await for (final chunk in response.stream.timeout(timeout)) {
              received += chunk.length;
              if (received > maxApkDownloadBytes) {
                throw StateError('APK 文件过大，已取消更新');
              }
              hashSink.add(chunk);
              await output.writeFrom(chunk);
              onProgress?.call(received, total);
            }
            hashClosed = true;
            hashSink.close();
            actualSha256 = digestSink.value.toString();
          } finally {
            if (!hashClosed) hashSink.close();
            await output.close();
          }

          if (actualSha256 != expectedSha256) {
            await tempFile.delete();
            throw StateError('APK SHA256 校验失败，已取消更新');
          }

          await tempFile.rename(apkFile.path);
          return apkFile;
        } catch (_) {
          if (await tempFile.exists()) await tempFile.delete();
          if (await apkFile.exists()) await apkFile.delete();
          if (attempt == downloadUris.length - 1) rethrow;
        }
      }
      throw StateError('没有可用的 APK 下载地址');
    } catch (_) {
      if (await tempFile.exists()) await tempFile.delete();
      if (await apkFile.exists()) await apkFile.delete();
      if (await updateDir.exists() && updateDir.listSync().isEmpty) {
        await updateDir.delete();
      }
      rethrow;
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  static Future<Map<Object?, Object?>> installDownloadedApk(
      File apkFile) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'installUpdate',
      {'apkPath': apkFile.path},
    );
    return result ?? const <Object?, Object?>{};
  }

  static Future<void> openDownload(String url) => openExternalUrl(url);

  static void showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    required String changelog,
    String? sha256,
    String? fallbackDownloadUrl,
  }) {
    final update = AppUpdateInfo(
      version: latestVersion,
      downloadUrl: downloadUrl,
      changelog: changelog,
      sha256: sha256,
      fallbackDownloadUrl: fallbackDownloadUrl,
    );

    SharedUpdateService.showUpdateDialog(
      context,
      latestVersion: latestVersion,
      currentVersion: currentVersion,
      downloadUrl: downloadUrl,
      fallbackDownloadUrl: fallbackDownloadUrl,
      changelog: changelog,
      primaryColor: AppTheme.primaryColor,
      accentColor: AppTheme.accentColor,
      textPrimary: AppTheme.darkTextPrimary,
      textSecondary: AppTheme.darkTextSecondary,
      lightTextPrimary: AppTheme.lightTextPrimary,
      lightTextSecondary: AppTheme.lightTextSecondary,
      openDownload: (_) => downloadAndInstallUpdate(context, update),
    );
  }

  static Future<void> downloadAndInstallUpdate(
    BuildContext context,
    AppUpdateInfo update, {
    http.Client? client,
    Directory? outputDirectory,
    Future<Map<Object?, Object?>> Function(File apkFile)? installApk,
  }) async {
    var receivedBytes = 0;
    int? totalBytes;
    StateSetter? updateDialogState;

    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          updateDialogState = setDialogState;
          final progress = totalBytes == null || totalBytes == 0
              ? null
              : receivedBytes / totalBytes!;
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('正在更新'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 12),
                  Text(_formatDownloadProgress(receivedBytes, totalBytes)),
                ],
              ),
            ),
          );
        },
      ),
    );

    try {
      final apkFile = await downloadUpdateApk(
        update,
        client: client,
        outputDirectory: outputDirectory,
        onProgress: (received, total) {
          receivedBytes = received;
          totalBytes = total;
          updateDialogState?.call(() {});
        },
      );

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      final installResult = await (installApk ?? installDownloadedApk)(apkFile);
      final status = installResult['status']?.toString();
      if (status == 'permissionRequired' && context.mounted) {
        _showUpdateMessage(
          context,
          '请允许 SSRVPN 安装未知来源应用，返回后会自动继续安装。',
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showUpdateMessage(context, '更新失败: ${_cleanError(e)}');
      }
      AppLogger.warning('Update', '应用内更新失败: $e');
    }
  }

  static String _formatDownloadProgress(int receivedBytes, int? totalBytes) {
    final received = _formatBytes(receivedBytes);
    if (totalBytes == null || totalBytes <= 0) {
      return '已下载 $received';
    }
    return '已下载 $received / ${_formatBytes(totalBytes)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  static String _cleanError(Object error) =>
      error.toString().replaceFirst('Bad state: ', '');

  static void _showUpdateMessage(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('更新提示'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

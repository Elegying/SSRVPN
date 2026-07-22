import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';

class UpdateDownloadCancelled implements Exception {
  @override
  String toString() => '更新已取消';
}

class UpdateDownloadCancellation {
  final Completer<void> _cancelled = Completer<void>();
  void Function()? _abortRequest;

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    _abortRequest?.call();
  }

  void _attach(void Function() abortRequest) {
    _abortRequest = abortRequest;
    if (isCancelled) abortRequest();
  }

  void _detach() => _abortRequest = null;

  void throwIfCancelled() {
    if (isCancelled) throw UpdateDownloadCancelled();
  }
}

/// 在线更新服务 - 基于 GitHub Releases
class UpdateService {
  /// 当前应用版本（发版时与 pubspec.yaml 的 version 同步修改）
  static const String appVersion = AppConstants.appVersion;

  /// 防止异常或恶意响应耗尽设备存储与内存。
  static const int maxApkDownloadBytes = 200 * 1024 * 1024;

  /// Android 原生通道（openUrl 注册在 MainActivity 的 com.ssrvpn/native 上）
  static const _channel = MethodChannel('com.ssrvpn/native');
  static bool _updatePromptVisible = false;
  static bool _downloadInProgress = false;
  static final Set<String> _promptedVersions = <String>{};

  static bool get isUpdateUiBusy => _updatePromptVisible || _downloadInProgress;

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
    UpdateDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
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
    final Directory baseDir = outputDirectory ??
        await _awaitWithCancellation(
          getTemporaryDirectory(),
          cancellation,
        );
    cancellation?.throwIfCancelled();
    final updateDir = Directory('${baseDir.path}/ssrvpn_update');
    if (!await _awaitWithCancellation(updateDir.exists(), cancellation)) {
      await _awaitWithCancellation(
        updateDir.create(recursive: true),
        cancellation,
      );
    }

    final apkFile = File('${updateDir.path}/SSRVPN-${update.version}.apk');
    final tempFile = File('${apkFile.path}.part');
    await _awaitWithCancellation(
      _pruneOldUpdateFiles(updateDir, keep: {apkFile.path, tempFile.path}),
      cancellation,
    );
    if (await _awaitWithCancellation(tempFile.exists(), cancellation)) {
      await _awaitWithCancellation(tempFile.delete(), cancellation);
    }
    if (await _awaitWithCancellation(apkFile.exists(), cancellation)) {
      await _awaitWithCancellation(apkFile.delete(), cancellation);
    }
    cancellation?.throwIfCancelled();

    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      if (ownsClient) cancellation?._attach(httpClient.close);
      for (var attempt = 0; attempt < downloadUris.length; attempt++) {
        cancellation?.throwIfCancelled();
        final uri = downloadUris[attempt];
        final attemptClock = Stopwatch()..start();
        try {
          final request = http.Request('GET', uri)
            ..headers['User-Agent'] = AppConstants.appUserAgent;
          final response = await _sendResponse(
            httpClient,
            request,
            cancellation,
            attemptClock: attemptClock,
            timeout: timeout,
          );
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
            await for (final chunk in _cancellableStream(
              response.stream,
              cancellation,
              attemptClock: attemptClock,
              timeout: timeout,
            )) {
              cancellation?.throwIfCancelled();
              received += chunk.length;
              if (received > maxApkDownloadBytes) {
                throw StateError('APK 文件过大，已取消更新');
              }
              hashSink.add(chunk);
              await output.writeFrom(chunk);
              onProgress?.call(received, total);
            }
            cancellation?.throwIfCancelled();
            hashClosed = true;
            hashSink.close();
            actualSha256 = digestSink.value.toString();
          } finally {
            if (!hashClosed) hashSink.close();
            await output.close();
          }
          cancellation?.throwIfCancelled();

          if (actualSha256 != expectedSha256) {
            await tempFile.delete();
            throw StateError('APK SHA256 校验失败，已取消更新');
          }

          cancellation?.throwIfCancelled();
          await tempFile.rename(apkFile.path);
          cancellation?.throwIfCancelled();
          return apkFile;
        } catch (_) {
          if (await tempFile.exists()) await tempFile.delete();
          if (await apkFile.exists()) await apkFile.delete();
          cancellation?.throwIfCancelled();
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
      cancellation?._detach();
      if (ownsClient) httpClient.close();
    }
  }

  static Future<T> _awaitWithCancellation<T>(
    Future<T> operation,
    UpdateDownloadCancellation? cancellation,
  ) {
    if (cancellation == null) return operation;
    return Future.any<T>([
      operation,
      cancellation.whenCancelled.then<T>(
        (_) => throw UpdateDownloadCancelled(),
      ),
    ]);
  }

  static Future<http.StreamedResponse> _sendResponse(
    http.Client client,
    http.BaseRequest request,
    UpdateDownloadCancellation? cancellation, {
    required Stopwatch attemptClock,
    required Duration timeout,
  }) async {
    final responseFuture = client.send(request);
    try {
      return await _awaitWithCancellation(
        responseFuture.timeout(_remainingAttemptTime(attemptClock, timeout)),
        cancellation,
      );
    } catch (_) {
      unawaited(
        responseFuture.then<void>(
          _cancelUnusedResponse,
          onError: (Object _, StackTrace __) {},
        ),
      );
      rethrow;
    }
  }

  static Future<void> _cancelUnusedResponse(
    http.StreamedResponse response,
  ) async {
    try {
      final subscription = response.stream.listen((_) {});
      await subscription.cancel();
    } catch (_) {
      // The request already lost its timeout/cancellation race. Cleanup is
      // best-effort and must not replace the original error.
    }
  }

  static Future<void> _pruneOldUpdateFiles(
    Directory directory, {
    required Set<String> keep,
  }) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || keep.contains(entity.path)) continue;
      final name = entity.uri.pathSegments.last;
      if (RegExp(r'^SSRVPN-.+\.apk(?:\.part)?$').hasMatch(name)) {
        try {
          await entity.delete();
        } catch (_) {
          // Cache cleanup is best-effort and must not block a verified update.
        }
      }
    }
  }

  static Stream<List<int>> _cancellableStream(
    Stream<List<int>> source,
    UpdateDownloadCancellation? cancellation, {
    required Stopwatch attemptClock,
    required Duration timeout,
  }) async* {
    final iterator = StreamIterator<List<int>>(source);
    try {
      while (await _awaitWithCancellation(
        iterator.moveNext().timeout(
              _remainingAttemptTime(attemptClock, timeout),
            ),
        cancellation,
      )) {
        yield iterator.current;
      }
    } finally {
      await iterator.cancel();
    }
  }

  static Duration _remainingAttemptTime(
    Stopwatch attemptClock,
    Duration timeout,
  ) {
    final remaining = timeout - attemptClock.elapsed;
    if (remaining.inMicroseconds <= 0) {
      throw TimeoutException('APK 下载超过总时限');
    }
    return remaining;
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

  static Future<void> showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    required String changelog,
    String? sha256,
    String? fallbackDownloadUrl,
  }) async {
    if (isUpdateUiBusy || _promptedVersions.contains(latestVersion)) return;
    _updatePromptVisible = true;
    _promptedVersions.add(latestVersion);
    final update = AppUpdateInfo(
      version: latestVersion,
      downloadUrl: downloadUrl,
      changelog: changelog,
      sha256: sha256,
      fallbackDownloadUrl: fallbackDownloadUrl,
    );

    try {
      await SharedUpdateService.showUpdateDialog(
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
        openDownload: (url) => downloadAndInstallUpdate(
          context,
          SharedUpdateService.preferDownloadUrl(update, url),
        ),
      );
    } catch (_) {
      _promptedVersions.remove(latestVersion);
      rethrow;
    } finally {
      _updatePromptVisible = false;
    }
  }

  static Future<void> downloadAndInstallUpdate(
    BuildContext context,
    AppUpdateInfo update, {
    http.Client? client,
    Directory? outputDirectory,
    Future<Map<Object?, Object?>> Function(File apkFile)? installApk,
  }) async {
    if (_downloadInProgress) return;
    _downloadInProgress = true;
    var receivedBytes = 0;
    int? totalBytes;
    StateSetter? updateDialogState;
    var progressDialogOpen = false;
    Future<void>? progressDialogFuture;
    Future<void>? progressDialogCloseFuture;
    var userCancelled = false;
    final cancellation = UpdateDownloadCancellation();

    Future<void> closeProgressDialog() {
      final pendingClose = progressDialogCloseFuture;
      if (pendingClose != null) return pendingClose;
      final close = () async {
        if (!progressDialogOpen) return;
        progressDialogOpen = false;
        updateDialogState = null;
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        await progressDialogFuture;
      }();
      progressDialogCloseFuture = close;
      return close;
    }

    if (!context.mounted) {
      _downloadInProgress = false;
      return;
    }
    try {
      await AppModalCoordinator.run<void>(() async {
        if (!context.mounted) return;
        try {
          progressDialogFuture = showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, setDialogState) {
                updateDialogState = setDialogState;
                final progress = totalBytes == null || totalBytes == 0
                    ? null
                    : (receivedBytes / totalBytes!).clamp(0.0, 1.0);
                return PopScope(
                  canPop: false,
                  child: AlertDialog(
                    scrollable: true,
                    title: const Text('正在更新'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 12),
                        Text(
                          _formatDownloadProgress(receivedBytes, totalBytes),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          userCancelled = true;
                          cancellation.cancel();
                          unawaited(closeProgressDialog());
                        },
                        child: const Text('取消更新'),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
          progressDialogOpen = true;
          final apkFile = await downloadUpdateApk(
            update,
            client: client,
            outputDirectory: outputDirectory,
            cancellation: cancellation,
            onProgress: (received, total) {
              receivedBytes = received;
              totalBytes = total;
              if (progressDialogOpen) updateDialogState?.call(() {});
            },
          );

          cancellation.throwIfCancelled();
          final progressDialogClosed = closeProgressDialog();
          cancellation.throwIfCancelled();
          final installResult =
              await (installApk ?? installDownloadedApk)(apkFile);
          final status = installResult['status']?.toString();
          if (status == 'permissionRequired') {
            await progressDialogClosed;
            if (context.mounted) {
              await _showUpdateMessage(
                context,
                '请允许 SSRVPN 安装未知来源应用，返回后会自动继续安装。',
              );
            }
          }
        } catch (e) {
          final cancelled = userCancelled || e is UpdateDownloadCancelled;
          await closeProgressDialog();
          if (!cancelled && context.mounted) {
            await _showUpdateMessage(
              context,
              '更新失败: ${_cleanError(e)}',
            );
          }
          if (!cancelled) AppLogger.warning('Update', '应用内更新失败: $e');
        } finally {
          await closeProgressDialog();
        }
      });
    } finally {
      _downloadInProgress = false;
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

  static Future<void> _showUpdateMessage(
    BuildContext context,
    String message,
  ) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
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

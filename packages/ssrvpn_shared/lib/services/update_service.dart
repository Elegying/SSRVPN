import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'update_checker.dart';

typedef DownloadOpener = Future<void> Function(String url);
typedef VerifiedUpdateOpener = Future<void> Function(File file);

class VerifiedUpdateCancelled implements Exception {
  @override
  String toString() => '更新已取消';
}

class VerifiedUpdateCancellation {
  final Completer<void> _cancelled = Completer<void>();
  void Function()? _abort;

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    _abort?.call();
  }

  void _attach(void Function() abort) {
    _abort = abort;
    if (isCancelled) abort();
  }

  void _detach() => _abort = null;

  void throwIfCancelled() {
    if (isCancelled) throw VerifiedUpdateCancelled();
  }
}

class SharedUpdateService {
  static const int maxDesktopUpdateBytes = 300 * 1024 * 1024;
  static bool _verifiedDownloadInProgress = false;

  static bool get isVerifiedDownloadInProgress => _verifiedDownloadInProgress;

  static Future<AppUpdateInfo?> checkForUpdate({
    required String currentVersion,
    required String assetExtension,
  }) async {
    final update = await UpdateChecker.checkLatest(
      currentVersion: currentVersion,
      assetExtension: assetExtension,
    );
    return update;
  }

  static Uri validateDownloadUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('Invalid download URL');
    }
    return uri;
  }

  static AppUpdateInfo preferDownloadUrl(
    AppUpdateInfo update,
    String downloadUrl,
  ) {
    if (downloadUrl == update.downloadUrl) return update;
    if (downloadUrl != update.fallbackDownloadUrl) {
      throw ArgumentError.value(downloadUrl, 'downloadUrl');
    }
    return AppUpdateInfo(
      version: update.version,
      downloadUrl: downloadUrl,
      fallbackDownloadUrl: update.downloadUrl,
      changelog: update.changelog,
      sha256: update.sha256,
      sourceHost: Uri.tryParse(downloadUrl)?.host,
    );
  }

  static Future<File> downloadVerifiedUpdate(
    AppUpdateInfo update, {
    required Directory outputDirectory,
    required String fileName,
    int maxBytes = maxDesktopUpdateBytes,
    http.Client? client,
    Duration timeout = const Duration(minutes: 2),
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    VerifiedUpdateCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(fileName)) {
      throw const FormatException('Invalid update file name');
    }
    final expectedSha256 = update.sha256?.trim().toLowerCase();
    if (expectedSha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
      throw StateError('缺少有效的更新文件 SHA256，已取消更新');
    }
    final uris = <Uri>[validateDownloadUrl(update.downloadUrl)];
    final fallback = update.fallbackDownloadUrl?.trim();
    if (fallback != null && fallback.isNotEmpty) {
      final fallbackUri = validateDownloadUrl(fallback);
      if (fallbackUri != uris.first) uris.add(fallbackUri);
    }

    await outputDirectory.create(recursive: true);
    final destination = File('${outputDirectory.path}/$fileName');
    final temporary = File('${destination.path}.part');
    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    cancellation?._attach(httpClient.close);
    try {
      if (await temporary.exists()) await temporary.delete();
      if (await destination.exists()) await destination.delete();
      for (var attempt = 0; attempt < uris.length; attempt++) {
        cancellation?.throwIfCancelled();
        try {
          final request = http.Request('GET', uris[attempt])
            ..headers['User-Agent'] = 'SSRVPN/${update.version}';
          final response = await _awaitWithCancellation(
            httpClient.send(request).timeout(timeout),
            cancellation,
          );
          if (response case http.BaseResponseWithUrl(:final url)) {
            if (url.scheme != 'https' || url.host.isEmpty) {
              await response.stream.listen((_) {}).cancel();
              throw const FormatException('Invalid final update URL');
            }
          }
          if (response.statusCode != HttpStatus.ok) {
            await response.stream.listen((_) {}).cancel();
            throw StateError('下载更新失败: HTTP ${response.statusCode}');
          }
          final total = response.contentLength;
          if (total != null && total > maxBytes) {
            await response.stream.listen((_) {}).cancel();
            throw StateError('更新文件过大，已取消更新');
          }

          var received = 0;
          final output = await temporary.open(mode: FileMode.write);
          final digestSink = _UpdateDigestSink();
          final hashSink = sha256.startChunkedConversion(digestSink);
          var hashClosed = false;
          late final String actualSha256;
          try {
            await for (final chunk in _cancellableStream(
              response.stream.timeout(timeout),
              cancellation,
            )) {
              cancellation?.throwIfCancelled();
              received += chunk.length;
              if (received > maxBytes) {
                throw StateError('更新文件过大，已取消更新');
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
            throw StateError('更新文件 SHA256 校验失败，已取消更新');
          }
          await temporary.rename(destination.path);
          return destination;
        } catch (_) {
          if (await temporary.exists()) await temporary.delete();
          if (await destination.exists()) await destination.delete();
          cancellation?.throwIfCancelled();
          if (attempt == uris.length - 1) rethrow;
        }
      }
      throw StateError('没有可用的更新下载地址');
    } finally {
      cancellation?._detach();
      if (ownsClient) httpClient.close();
    }
  }

  static Future<T> _awaitWithCancellation<T>(
    Future<T> operation,
    VerifiedUpdateCancellation? cancellation,
  ) {
    if (cancellation == null) return operation;
    return Future.any<T>([
      operation,
      cancellation.whenCancelled.then<T>(
        (_) => throw VerifiedUpdateCancelled(),
      ),
    ]);
  }

  static Stream<List<int>> _cancellableStream(
    Stream<List<int>> source,
    VerifiedUpdateCancellation? cancellation,
  ) async* {
    if (cancellation == null) {
      yield* source;
      return;
    }
    final iterator = StreamIterator<List<int>>(source);
    try {
      while (await _awaitWithCancellation(
        iterator.moveNext(),
        cancellation,
      )) {
        yield iterator.current;
      }
    } finally {
      await iterator.cancel();
    }
  }

  static Future<void> downloadAndOpenVerifiedUpdate(
    BuildContext context,
    AppUpdateInfo update, {
    required String fileName,
    required VerifiedUpdateOpener openFile,
    Directory? outputDirectory,
    http.Client? client,
  }) async {
    if (!context.mounted || _verifiedDownloadInProgress) return;
    _verifiedDownloadInProgress = true;
    final cancellation = VerifiedUpdateCancellation();
    var receivedBytes = 0;
    int? totalBytes;
    var progressDialogOpen = true;
    var cancelledByUser = false;
    StateSetter? updateDialogState;

    unawaited(
      showDialog<void>(
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
                title: const Text('正在下载更新'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 12),
                    Text(_formatProgress(receivedBytes, totalBytes)),
                    const SizedBox(height: 8),
                    const Text('下载完成并通过 SHA256 校验后才会打开安装包。'),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      cancelledByUser = true;
                      cancellation.cancel();
                      if (progressDialogOpen) {
                        Navigator.of(dialogContext).pop();
                        progressDialogOpen = false;
                      }
                    },
                    child: const Text('取消更新'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    try {
      final file = await downloadVerifiedUpdate(
        update,
        outputDirectory: outputDirectory ??
            Directory('${Directory.systemTemp.path}/ssrvpn_update'),
        fileName: fileName,
        client: client,
        cancellation: cancellation,
        onProgress: (received, total) {
          receivedBytes = received;
          totalBytes = total;
          updateDialogState?.call(() {});
        },
      );
      if (context.mounted && progressDialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        progressDialogOpen = false;
      }
      await openFile(file);
    } catch (error) {
      final cancelled = cancelledByUser || error is VerifiedUpdateCancelled;
      if (context.mounted && progressDialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        progressDialogOpen = false;
      }
      if (!cancelled && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('更新失败'),
            content: Text(
              error.toString().replaceFirst('Bad state: ', ''),
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
    } finally {
      if (context.mounted && progressDialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _verifiedDownloadInProgress = false;
    }
  }

  static String _formatProgress(int receivedBytes, int? totalBytes) {
    final received = _formatBytes(receivedBytes);
    if (totalBytes == null || totalBytes <= 0) return '已下载 $received';
    return '已下载 $received / ${_formatBytes(totalBytes)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  static Future<void> showUpdateDialog(
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
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final viewport = MediaQuery.sizeOf(ctx);
        final maxWidth = math.min(
          420.0,
          math.max(280.0, viewport.width - 32),
        );
        final maxHeight = math.max(1.0, viewport.height - 32);

        return Dialog(
          backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: SingleChildScrollView(
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
      },
    );
  }
}

class _UpdateDigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

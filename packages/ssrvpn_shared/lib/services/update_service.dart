import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/app_diagnostics.dart';
import 'update_checker.dart';
import '../utils/app_modal_coordinator.dart';

part 'update_service_download.dart';
part 'update_service_publication.dart';

typedef DownloadOpener = Future<void> Function(String url);
typedef VerifiedUpdateHandler = Future<void> Function(File file);
typedef VerifiedUpdateOpener = VerifiedUpdateHandler;
typedef VerifiedUpdatePreparer = Future<bool> Function();

/// Atomically publishes [source] at [destination] without replacing an
/// existing path.
typedef VerifiedUpdateFilePublisher = Future<void> Function(
  File source,
  File destination,
);

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

@visibleForTesting
enum VerifiedUpdateRecoveryTestStep {
  scanEntry,
  beforeSourceRead,
  beforeStagingWrite,
  hashedChunk,
  verifiedCopy,
  committed,
}

@visibleForTesting
enum VerifiedUpdatePublicationTestStep {
  downloadVerified,
  beforeDestinationCommit,
  committed,
  reused,
}

class SharedUpdateService {
  static const int maxDesktopUpdateBytes = 300 * 1024 * 1024;
  static bool _verifiedDownloadInProgress = false;

  static bool get isVerifiedDownloadInProgress => _verifiedDownloadInProgress;

  @visibleForTesting
  static set recoveryDirectoryEntryLimitForTesting(int? limit) {
    if (limit != null && (limit <= 0 || limit > _recoveryDirectoryEntryLimit)) {
      throw RangeError.range(
        limit,
        1,
        _recoveryDirectoryEntryLimit,
        'limit',
      );
    }
    _recoveryDirectoryEntryLimitForTesting = limit;
  }

  @visibleForTesting
  static set recoveryStepForTesting(
    void Function(VerifiedUpdateRecoveryTestStep)? callback,
  ) {
    _recoveryStepForTesting = callback;
  }

  @visibleForTesting
  static set publicationStepForTesting(
    FutureOr<void> Function(VerifiedUpdatePublicationTestStep)? callback,
  ) {
    _publicationStepForTesting = callback;
  }

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
    VerifiedUpdateFilePublisher? filePublisher,
  }) {
    return _downloadVerifiedUpdate(
      update,
      outputDirectory: outputDirectory,
      fileName: fileName,
      maxBytes: maxBytes,
      client: client,
      timeout: timeout,
      onProgress: onProgress,
      cancellation: cancellation,
      filePublisher: filePublisher,
    );
  }

  static Future<void> downloadAndOpenVerifiedUpdate(
    BuildContext context,
    AppUpdateInfo update, {
    required String fileName,
    required VerifiedUpdateOpener openFile,
    VerifiedUpdatePreparer? beforeOpen,
    Directory? outputDirectory,
    http.Client? client,
  }) {
    return downloadVerifiedUpdateWithProgress(
      context,
      update,
      fileName: fileName,
      onVerified: (file) async {
        if (beforeOpen != null && !await beforeOpen()) {
          throw StateError('无法安全断开当前连接，已阻止打开更新安装包');
        }
        await openFile(file);
      },
      outputDirectory: outputDirectory,
      client: client,
      progressDescription: '下载完成并通过 SHA256 校验后才会打开安装包。',
    );
  }

  static Future<void> downloadVerifiedUpdateWithProgress(
    BuildContext context,
    AppUpdateInfo update, {
    required String fileName,
    required VerifiedUpdateHandler onVerified,
    required String progressDescription,
    Directory? outputDirectory,
    http.Client? client,
    VerifiedUpdateFilePublisher? filePublisher,
  }) async {
    if (!context.mounted || _verifiedDownloadInProgress) return;
    _verifiedDownloadInProgress = true;
    final cancellation = VerifiedUpdateCancellation();
    var receivedBytes = 0;
    int? totalBytes;
    var progressDialogOpen = false;
    Future<void>? progressDialogFuture;
    Future<void>? progressDialogCloseFuture;
    var cancelledByUser = false;
    StateSetter? updateDialogState;

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
                    title: const Text('正在下载更新'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 12),
                        Text(_formatProgress(receivedBytes, totalBytes)),
                        const SizedBox(height: 8),
                        Text(progressDescription),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          cancelledByUser = true;
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
          final file = await downloadVerifiedUpdate(
            update,
            outputDirectory: outputDirectory ??
                Directory('${Directory.systemTemp.path}/ssrvpn_update'),
            fileName: fileName,
            client: client,
            cancellation: cancellation,
            filePublisher: filePublisher,
            onProgress: (received, total) {
              receivedBytes = received;
              totalBytes = total;
              if (progressDialogOpen) updateDialogState?.call(() {});
            },
          );
          // Returning from downloadVerifiedUpdate means the verified file has
          // crossed its publication commit point. A cancel click racing with
          // that final rename can no longer roll the file back, so the UI must
          // still acknowledge the completed download.
          await closeProgressDialog();
          await onVerified(file);
        } catch (error) {
          final cancelled = cancelledByUser || error is VerifiedUpdateCancelled;
          await closeProgressDialog();
          if (!cancelled && context.mounted) {
            await showDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                scrollable: true,
                title: const Text('更新失败'),
                content: Text(safeUserFacingFailureMessage(error)),
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
          await closeProgressDialog();
        }
      });
    } finally {
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
    String primaryActionLabel = '立即更新',
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await AppModalCoordinator.run<void>(() {
      if (!context.mounted) return Future.value();
      return showDialog<void>(
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
                              color:
                                  isDark ? textSecondary : lightTextSecondary,
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
                                color:
                                    isDark ? textSecondary : lightTextSecondary,
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
                            child: Text(
                              primaryActionLabel,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.white,
                              ),
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
                        child: const Text('使用备用下载地址'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      );
    });
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'update_checker.dart';
import '../utils/app_modal_coordinator.dart';

typedef DownloadOpener = Future<void> Function(String url);
typedef VerifiedUpdateHandler = Future<void> Function(File file);
typedef VerifiedUpdateOpener = VerifiedUpdateHandler;
typedef VerifiedUpdatePreparer = Future<bool> Function();

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
  beforeDestinationCommit,
  committed,
  reused,
}

class SharedUpdateService {
  static const int maxDesktopUpdateBytes = 300 * 1024 * 1024;
  // Recovery runs before the network request and scans a user-writable
  // directory, so every dimension needs a hard upper bound.
  static const int _recoveryDirectoryEntryLimit = 4096;
  static const int _recoveryCandidateLimit = 16;
  static const int _recoveryTotalByteLimit = 2 * maxDesktopUpdateBytes;
  static const int _recoveryHashChunkBytes = 64 * 1024;
  static const Duration _publicationLockTimeout = Duration(seconds: 15);
  static const Duration _publicationLockRetryDelay = Duration(
    milliseconds: 25,
  );
  static const Duration _publicationLeaseProbeTimeout = Duration(seconds: 5);
  static bool _verifiedDownloadInProgress = false;
  static int? _recoveryDirectoryEntryLimitForTesting;
  static void Function(VerifiedUpdateRecoveryTestStep)? _recoveryStepForTesting;
  static FutureOr<void> Function(VerifiedUpdatePublicationTestStep)?
      _publicationStepForTesting;

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

    await _awaitWithCancellation(
      outputDirectory.create(recursive: true),
      cancellation,
    );
    final destination = File('${outputDirectory.path}/$fileName');
    final recovered = await _withPublicationLock(
      destination,
      cancellation: cancellation,
      action: () => _recoverInterruptedPublicationLocked(
        destination,
        expectedSha256: expectedSha256,
        maxBytes: maxBytes,
        cancellation: cancellation,
      ),
    );
    if (recovered) {
      cancellation?.throwIfCancelled();
      return destination;
    }
    final publicationId = '${pid}_${DateTime.now().microsecondsSinceEpoch}_'
        '${math.Random.secure().nextInt(0x7fffffff)}';
    final temporary = File('${destination.path}.part.$publicationId');
    cancellation?.throwIfCancelled();
    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      if (ownsClient) cancellation?._attach(httpClient.close);
      var verifiedDownloadReady = false;
      for (var attempt = 0; attempt < uris.length; attempt++) {
        cancellation?.throwIfCancelled();
        final attemptClock = Stopwatch()..start();
        try {
          final request = http.Request('GET', uris[attempt])
            ..headers['User-Agent'] = 'SSRVPN/${update.version}';
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
              response.stream,
              cancellation,
              attemptClock: attemptClock,
              timeout: timeout,
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
            throw StateError('更新文件 SHA256 校验失败，已取消更新');
          }
          cancellation?.throwIfCancelled();
          verifiedDownloadReady = true;
          break;
        } catch (_) {
          if (await temporary.exists()) await temporary.delete();
          cancellation?.throwIfCancelled();
          if (attempt == uris.length - 1) rethrow;
        }
      }
      if (!verifiedDownloadReady) {
        throw StateError('没有可用的更新下载地址');
      }

      cancellation?.throwIfCancelled();
      final verifiedLength = await _awaitWithCancellation(
        temporary.length(),
        cancellation,
      );
      try {
        await _withPublicationLock<void>(
          destination,
          cancellation: cancellation,
          action: () => _publishVerifiedFileLocked(
            temporary: temporary,
            destination: destination,
            expectedSha256: expectedSha256,
            expectedLength: verifiedLength,
            maxBytes: maxBytes,
            cancellation: cancellation,
          ),
        );
      } catch (_) {
        await _deleteRecoveryBackupBestEffort(temporary, null);
        rethrow;
      }
      return destination;
    } finally {
      cancellation?._detach();
      if (ownsClient) httpClient.close();
    }
  }

  static Future<_VerifiedPublicationOutcome> _publishVerifiedFileLocked({
    required File temporary,
    required File destination,
    required String expectedSha256,
    required int expectedLength,
    required int maxBytes,
    VerifiedUpdateCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final destinationType = await _awaitWithCancellation(
      FileSystemEntity.type(destination.path, followLinks: false),
      cancellation,
    );
    cancellation?.throwIfCancelled();
    if (destinationType == FileSystemEntityType.file) {
      final matches = await _verifiedFileMatches(
        destination,
        expectedSha256: expectedSha256,
        expectedLength: expectedLength,
        maxBytes: maxBytes,
        cancellation: cancellation,
      );
      if (!matches) {
        throw StateError('目标更新文件已存在且校验不一致，已拒绝覆盖');
      }
      await _deleteRecoveryBackupBestEffort(temporary, null);
      await _notifyPublicationStep(
        VerifiedUpdatePublicationTestStep.reused,
      );
      return _VerifiedPublicationOutcome.reused;
    }
    if (destinationType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        '目标更新路径不是普通文件，已拒绝覆盖',
        destination.path,
      );
    }
    cancellation?.throwIfCancelled();
    await _notifyPublicationStep(
      VerifiedUpdatePublicationTestStep.beforeDestinationCommit,
    );
    cancellation?.throwIfCancelled();
    final linked = await _createHardLinkNoReplace(
      source: temporary,
      destination: destination,
      cancellation: cancellation,
    );
    if (!linked) {
      final matches = await _verifiedFileMatches(
        destination,
        expectedSha256: expectedSha256,
        expectedLength: expectedLength,
        maxBytes: maxBytes,
        cancellation: cancellation,
      );
      if (!matches) {
        throw StateError('目标更新文件在发布时已存在且校验不一致，已拒绝覆盖');
      }
      await _deleteRecoveryBackupBestEffort(temporary, null);
      await _notifyPublicationStep(
        VerifiedUpdatePublicationTestStep.reused,
      );
      return _VerifiedPublicationOutcome.reused;
    }
    final committedMatches = await _verifiedFileMatches(
      destination,
      expectedSha256: expectedSha256,
      expectedLength: expectedLength,
      maxBytes: maxBytes,
      cancellation: cancellation,
    );
    if (!committedMatches) {
      throw StateError('更新文件原子发布后的校验失败，已拒绝使用');
    }
    await _deleteRecoveryBackupBestEffort(temporary, null);
    await _notifyPublicationStep(
      VerifiedUpdatePublicationTestStep.committed,
    );
    return _VerifiedPublicationOutcome.committed;
  }

  /// Creates the destination as a hard link to the already verified staging
  /// inode. Hard-link creation is atomic and fails when the destination exists,
  /// so the commit point can never replace a user or another process's file.
  static Future<bool> _createHardLinkNoReplace({
    required File source,
    required File destination,
    required VerifiedUpdateCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    late final ProcessResult result;
    if (Platform.isWindows) {
      const script = r'''
param([string]$SourcePath, [string]$DestinationPath)
$ErrorActionPreference = 'Stop'
New-Item -ItemType HardLink -Path $DestinationPath -Target $SourcePath -ErrorAction Stop | Out-Null
''';
      result = await _awaitWithCancellation(
        Process.run(
          'powershell.exe',
          <String>[
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            script,
            source.absolute.path,
            destination.absolute.path,
          ],
        ),
        cancellation,
      );
    } else {
      result = await _awaitWithCancellation(
        Process.run(
          '/bin/ln',
          <String>[source.absolute.path, destination.absolute.path],
        ),
        cancellation,
      );
    }
    cancellation?.throwIfCancelled();
    if (result.exitCode == 0) return true;
    final destinationType = await _awaitWithCancellation(
      FileSystemEntity.type(destination.path, followLinks: false),
      cancellation,
    );
    if (destinationType != FileSystemEntityType.notFound) return false;
    final details = result.stderr.toString().trim();
    throw FileSystemException(
      details.isEmpty ? '无法原子发布更新文件' : details,
      destination.path,
    );
  }

  static Future<bool> _recoverInterruptedPublicationLocked(
    File destination, {
    required String expectedSha256,
    required int maxBytes,
    VerifiedUpdateCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final destinationType = await _awaitWithCancellation(
      FileSystemEntity.type(destination.path, followLinks: false),
      cancellation,
    );
    cancellation?.throwIfCancelled();
    if (destinationType != FileSystemEntityType.notFound &&
        destinationType != FileSystemEntityType.file) {
      throw FileSystemException(
        '目标更新路径不是普通文件，已拒绝覆盖',
        destination.path,
      );
    }
    final destinationMatches = destinationType == FileSystemEntityType.file
        ? await _verifiedFileMatches(
            destination,
            expectedSha256: expectedSha256,
            maxBytes: maxBytes,
            cancellation: cancellation,
          )
        : false;

    final prefix = '${destination.path}.previous.';
    final backups = <({File file, DateTime modified, int length})>[];
    final entries = StreamIterator<FileSystemEntity>(
      destination.parent.list(followLinks: false),
    );
    var scannedEntries = 0;
    try {
      while (scannedEntries <
              (_recoveryDirectoryEntryLimitForTesting ??
                  _recoveryDirectoryEntryLimit) &&
          await _awaitWithCancellation(entries.moveNext(), cancellation)) {
        cancellation?.throwIfCancelled();
        scannedEntries++;
        _recoveryStepForTesting?.call(
          VerifiedUpdateRecoveryTestStep.scanEntry,
        );
        cancellation?.throwIfCancelled();

        final entity = entries.current;
        if (entity is! File || !entity.path.startsWith(prefix)) continue;
        final suffix = entity.path.substring(prefix.length);
        if (!RegExp(r'^\d+_\d+_\d+$').hasMatch(suffix)) continue;
        if (await _awaitWithCancellation(
              FileSystemEntity.type(entity.path, followLinks: false),
              cancellation,
            ) !=
            FileSystemEntityType.file) {
          continue;
        }
        cancellation?.throwIfCancelled();
        final stat = await _awaitWithCancellation(entity.stat(), cancellation);
        cancellation?.throwIfCancelled();
        if (stat.size < 0 || stat.size > maxBytes) {
          await _deleteRecoveryBackupBestEffort(entity, cancellation);
          continue;
        }

        backups.add((
          file: entity,
          modified: stat.modified,
          length: stat.size,
        ));
        backups.sort((left, right) {
          final byModified = right.modified.compareTo(left.modified);
          if (byModified != 0) return byModified;
          return right.file.path.compareTo(left.file.path);
        });
        if (backups.length > _recoveryCandidateLimit) {
          final discarded = backups.removeLast();
          await _deleteRecoveryBackupBestEffort(
            discarded.file,
            cancellation,
          );
        }
      }
    } finally {
      try {
        await entries.cancel();
      } catch (_) {}
    }
    if (backups.isEmpty) {
      if (destinationType == FileSystemEntityType.file) {
        if (destinationMatches) return true;
        throw StateError('目标更新文件已存在且校验不一致，已拒绝覆盖');
      }
      return false;
    }

    Future<void> cleanBackups() async {
      // A backup is publishable only when it matches trusted update metadata.
      // Everything left after recovery is stale or unverified private state.
      for (final backup in backups) {
        cancellation?.throwIfCancelled();
        await _deleteRecoveryBackupBestEffort(backup.file, cancellation);
      }
    }

    if (destinationType == FileSystemEntityType.file) {
      await cleanBackups();
      if (destinationMatches) return true;
      throw StateError('目标更新文件已存在且校验不一致，已拒绝覆盖');
    }

    var recovered = false;
    final recoveryByteBudget = maxBytes <= 0
        ? 0
        : math.min(maxBytes * 2, _recoveryTotalByteLimit).toInt();
    var hashedBytes = 0;
    for (final backup in backups) {
      cancellation?.throwIfCancelled();
      final remainingBytes = recoveryByteBudget - hashedBytes;
      if (remainingBytes <= 0) break;
      if (backup.length > remainingBytes) continue;
      File? verifiedCopy;
      var published = false;
      try {
        final result = await _createVerifiedRecoveryCopy(
          source: backup.file,
          destination: destination,
          expectedSha256: expectedSha256,
          maxBytes: math.min(maxBytes, remainingBytes).toInt(),
          cancellation: cancellation,
        );
        hashedBytes += result.bytesRead;
        verifiedCopy = result.verifiedCopy;
        if (verifiedCopy == null) continue;

        _recoveryStepForTesting?.call(
          VerifiedUpdateRecoveryTestStep.verifiedCopy,
        );
        cancellation?.throwIfCancelled();
        final outcome = await _publishVerifiedFileLocked(
          temporary: verifiedCopy,
          destination: destination,
          expectedSha256: expectedSha256,
          expectedLength: result.bytesRead,
          maxBytes: maxBytes,
          cancellation: cancellation,
        );
        published = true;
        recovered = true;
        if (outcome == _VerifiedPublicationOutcome.committed) {
          _recoveryStepForTesting?.call(
            VerifiedUpdateRecoveryTestStep.committed,
          );
        }
        break;
      } finally {
        if (verifiedCopy != null && !published) {
          await _deleteRecoveryBackupBestEffort(verifiedCopy, null);
        }
      }
    }

    await cleanBackups();
    return recovered;
  }

  static Future<bool> _verifiedFileMatches(
    File file, {
    required String expectedSha256,
    int? expectedLength,
    required int maxBytes,
    VerifiedUpdateCancellation? cancellation,
  }) async {
    RandomAccessFile? input;
    final digestSink = _UpdateDigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var hashClosed = false;
    try {
      cancellation?.throwIfCancelled();
      if (maxBytes < 0 ||
          await _awaitWithCancellation(
                FileSystemEntity.type(file.path, followLinks: false),
                cancellation,
              ) !=
              FileSystemEntityType.file) {
        return false;
      }
      input = await _openRecoveryFile(file, cancellation);
      cancellation?.throwIfCancelled();
      final initialLength = await _awaitWithCancellation(
        input.length(),
        cancellation,
      );
      if (initialLength < 0 ||
          initialLength > maxBytes ||
          (expectedLength != null && initialLength != expectedLength)) {
        return false;
      }

      var bytesRead = 0;
      while (true) {
        cancellation?.throwIfCancelled();
        final chunk = await _awaitWithCancellation(
          input.read(_recoveryHashChunkBytes),
          cancellation,
        );
        cancellation?.throwIfCancelled();
        if (chunk.isEmpty) break;
        bytesRead += chunk.length;
        if (bytesRead > maxBytes ||
            (expectedLength != null && bytesRead > expectedLength)) {
          return false;
        }
        hashSink.add(chunk);
      }
      final finalLength = await _awaitWithCancellation(
        input.length(),
        cancellation,
      );
      cancellation?.throwIfCancelled();
      hashSink.close();
      hashClosed = true;
      return bytesRead == initialLength &&
          finalLength == initialLength &&
          (expectedLength == null || bytesRead == expectedLength) &&
          digestSink.value.toString() == expectedSha256;
    } on VerifiedUpdateCancelled {
      rethrow;
    } on FileSystemException {
      cancellation?.throwIfCancelled();
      return false;
    } finally {
      if (!hashClosed) hashSink.close();
      if (input != null) {
        try {
          await input.close();
        } catch (_) {}
      }
    }
  }

  static Future<T> _withPublicationLock<T>(
    File destination, {
    required VerifiedUpdateCancellation? cancellation,
    required Future<T> Function() action,
  }) async {
    final lease = await _acquirePublicationLock(destination, cancellation);
    try {
      cancellation?.throwIfCancelled();
      return await action();
    } finally {
      await lease.release();
    }
  }

  static Future<_VerifiedUpdatePublicationLease> _acquirePublicationLock(
    File destination,
    VerifiedUpdateCancellation? cancellation,
  ) async {
    final canonicalParent = await _awaitWithCancellation(
      destination.parent.resolveSymbolicLinks(),
      cancellation,
    );
    final destinationSuffix = destination.absolute.path.substring(
      destination.absolute.parent.path.length,
    );
    final canonicalPath = '$canonicalParent$destinationSuffix';
    final normalizedPath =
        Platform.isWindows ? canonicalPath.toLowerCase() : canonicalPath;
    final lockKey = sha256.convert(utf8.encode(normalizedPath)).toString();
    final isolateLockName = 'ssrvpn.update.publication.$lockKey';
    final waitClock = Stopwatch()..start();

    while (waitClock.elapsed < _publicationLockTimeout) {
      cancellation?.throwIfCancelled();
      final receivePort = ReceivePort();
      if (IsolateNameServer.registerPortWithName(
        receivePort.sendPort,
        isolateLockName,
      )) {
        final subscription = receivePort.listen((message) {
          if (message is SendPort) message.send(true);
        });
        try {
          final lockFile = await _acquirePublicationFileLock(
            lockKey,
            waitClock: waitClock,
            cancellation: cancellation,
          );
          return _VerifiedUpdatePublicationLease(
            isolateLockName: isolateLockName,
            receivePort: receivePort,
            subscription: subscription,
            lockFile: lockFile,
          );
        } catch (_) {
          if (IsolateNameServer.lookupPortByName(isolateLockName) ==
              receivePort.sendPort) {
            IsolateNameServer.removePortNameMapping(isolateLockName);
          }
          await subscription.cancel();
          receivePort.close();
          rethrow;
        }
      }
      receivePort.close();

      await _waitForIsolatePublicationLease(
        isolateLockName,
        waitClock: waitClock,
        cancellation: cancellation,
      );
    }
    throw TimeoutException('等待更新文件发布锁超时');
  }

  static Future<RandomAccessFile> _acquirePublicationFileLock(
    String lockKey, {
    required Stopwatch waitClock,
    required VerifiedUpdateCancellation? cancellation,
  }) async {
    final lockDirectory = Directory(
      '${Directory.systemTemp.path}/ssrvpn_update_publication_locks',
    );
    await _awaitWithCancellation(
      lockDirectory.create(recursive: true),
      cancellation,
    );
    final lockFile = await _openRecoveryFile(
      File('${lockDirectory.path}/$lockKey.lock'),
      cancellation,
      mode: FileMode.append,
    );
    try {
      while (waitClock.elapsed < _publicationLockTimeout) {
        cancellation?.throwIfCancelled();
        try {
          await _awaitWithCancellation(
            lockFile.lock(FileLock.exclusive),
            cancellation,
          );
          return lockFile;
        } on VerifiedUpdateCancelled {
          rethrow;
        } on FileSystemException {
          await _publicationLockDelay(waitClock, cancellation);
        }
      }
    } catch (_) {
      try {
        await lockFile.close();
      } catch (_) {}
      rethrow;
    }
    try {
      await lockFile.close();
    } catch (_) {}
    throw TimeoutException('等待更新文件发布锁超时');
  }

  static Future<void> _waitForIsolatePublicationLease(
    String isolateLockName, {
    required Stopwatch waitClock,
    required VerifiedUpdateCancellation? cancellation,
  }) async {
    final existing = IsolateNameServer.lookupPortByName(isolateLockName);
    if (existing == null) return;
    final reply = ReceivePort();
    try {
      existing.send(reply.sendPort);
      final remaining = _publicationLockTimeout - waitClock.elapsed;
      if (remaining <= Duration.zero) return;
      final probeTimeout = remaining < _publicationLeaseProbeTimeout
          ? remaining
          : _publicationLeaseProbeTimeout;
      try {
        await _awaitWithCancellation(
          reply.first.timeout(probeTimeout),
          cancellation,
        );
      } on TimeoutException {
        // IsolateNameServer mappings can outlive an abruptly terminated
        // isolate. Remove only the exact unresponsive mapping we probed.
        if (IsolateNameServer.lookupPortByName(isolateLockName) == existing) {
          IsolateNameServer.removePortNameMapping(isolateLockName);
        }
      }
    } finally {
      reply.close();
    }
    await _publicationLockDelay(waitClock, cancellation);
  }

  static Future<void> _publicationLockDelay(
    Stopwatch waitClock,
    VerifiedUpdateCancellation? cancellation,
  ) async {
    final remaining = _publicationLockTimeout - waitClock.elapsed;
    if (remaining <= Duration.zero) return;
    final delay = remaining < _publicationLockRetryDelay
        ? remaining
        : _publicationLockRetryDelay;
    await _awaitWithCancellation(Future<void>.delayed(delay), cancellation);
  }

  static Future<void> _notifyPublicationStep(
    VerifiedUpdatePublicationTestStep step,
  ) async {
    final callback = _publicationStepForTesting;
    if (callback != null) await callback(step);
  }

  static Future<({File? verifiedCopy, int bytesRead})>
      _createVerifiedRecoveryCopy({
    required File source,
    required File destination,
    required String expectedSha256,
    required int maxBytes,
    VerifiedUpdateCancellation? cancellation,
  }) async {
    RandomAccessFile? input;
    RandomAccessFile? output;
    File? staging;
    final digestSink = _UpdateDigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var hashClosed = false;
    var keepStaging = false;
    var bytesWritten = 0;
    try {
      late final FileStat initialStat;
      try {
        cancellation?.throwIfCancelled();
        if (await _awaitWithCancellation(
              FileSystemEntity.type(source.path, followLinks: false),
              cancellation,
            ) !=
            FileSystemEntityType.file) {
          return (verifiedCopy: null, bytesRead: bytesWritten);
        }
        cancellation?.throwIfCancelled();
        initialStat = await _awaitWithCancellation(
          source.stat(),
          cancellation,
        );
        cancellation?.throwIfCancelled();
      } on FileSystemException {
        cancellation?.throwIfCancelled();
        // A stale or locked source is only one recovery candidate. It must not
        // prevent trying another candidate or starting a fresh download.
        return (verifiedCopy: null, bytesRead: bytesWritten);
      }
      if (initialStat.size < 0 || initialStat.size > maxBytes) {
        return (verifiedCopy: null, bytesRead: bytesWritten);
      }

      late final RandomAccessFile openedInput;
      try {
        openedInput = await _openRecoveryFile(source, cancellation);
      } on FileSystemException {
        cancellation?.throwIfCancelled();
        return (verifiedCopy: null, bytesRead: bytesWritten);
      }
      input = openedInput;
      cancellation?.throwIfCancelled();
      // From this point, staging storage failures are surfaced: silently
      // retrying a download cannot repair a full or unwritable destination.
      staging = await _createUniqueRecoveryStagingFile(
        destination,
        cancellation,
      );
      cancellation?.throwIfCancelled();
      final openedOutput = await staging.open(mode: FileMode.write);
      output = openedOutput;
      cancellation?.throwIfCancelled();

      while (bytesWritten < initialStat.size) {
        cancellation?.throwIfCancelled();
        late final List<int> chunk;
        try {
          _recoveryStepForTesting?.call(
            VerifiedUpdateRecoveryTestStep.beforeSourceRead,
          );
          chunk = await openedInput.read(
            math
                .min(
                  _recoveryHashChunkBytes,
                  initialStat.size - bytesWritten,
                )
                .toInt(),
          );
        } on FileSystemException {
          cancellation?.throwIfCancelled();
          return (verifiedCopy: null, bytesRead: bytesWritten);
        }
        cancellation?.throwIfCancelled();
        if (chunk.isEmpty) {
          return (verifiedCopy: null, bytesRead: bytesWritten);
        }
        _recoveryStepForTesting?.call(
          VerifiedUpdateRecoveryTestStep.beforeStagingWrite,
        );
        await openedOutput.writeFrom(chunk);
        cancellation?.throwIfCancelled();
        hashSink.add(chunk);
        bytesWritten += chunk.length;
        _recoveryStepForTesting?.call(
          VerifiedUpdateRecoveryTestStep.hashedChunk,
        );
        cancellation?.throwIfCancelled();
      }
      await openedOutput.flush();
      cancellation?.throwIfCancelled();
      await openedOutput.close();
      output = null;
      hashSink.close();
      hashClosed = true;

      if (digestSink.value.toString() != expectedSha256) {
        return (verifiedCopy: null, bytesRead: bytesWritten);
      }
      keepStaging = true;
      return (verifiedCopy: staging, bytesRead: bytesWritten);
    } finally {
      if (!hashClosed) hashSink.close();
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (input != null) {
        try {
          await input.close();
        } catch (_) {}
      }
      if (staging != null && !keepStaging) {
        await _deleteRecoveryBackupBestEffort(staging, null);
      }
    }
  }

  static Future<File> _createUniqueRecoveryStagingFile(
    File destination,
    VerifiedUpdateCancellation? cancellation,
  ) async {
    final random = math.Random.secure();
    for (var attempt = 0; attempt < 8; attempt++) {
      cancellation?.throwIfCancelled();
      final entropy = List<String>.generate(
        4,
        (_) => random.nextInt(0x7fffffff).toString().padLeft(10, '0'),
        growable: false,
      ).join();
      final publicationId = '${pid}_${DateTime.now().microsecondsSinceEpoch}_'
          '$entropy';
      final staging = File('${destination.path}.previous.$publicationId');
      try {
        await staging.create(exclusive: true);
        return staging;
      } on FileSystemException {
        if (await FileSystemEntity.type(staging.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    throw StateError('无法创建唯一的更新恢复暂存文件');
  }

  static Future<void> _deleteRecoveryBackupBestEffort(
    File backup,
    VerifiedUpdateCancellation? cancellation,
  ) async {
    try {
      await _awaitWithCancellation(backup.delete(), cancellation);
    } on VerifiedUpdateCancelled {
      rethrow;
    } catch (_) {
      // Private recovery artifacts are best-effort cleanup only.
    }
  }

  static Future<RandomAccessFile> _openRecoveryFile(
    File file,
    VerifiedUpdateCancellation? cancellation, {
    FileMode mode = FileMode.read,
  }) async {
    final opening = file.open(mode: mode);
    try {
      return await _awaitWithCancellation(opening, cancellation);
    } catch (_) {
      unawaited(
        opening.then<void>(
          (lateInput) async {
            try {
              await lateInput.close();
            } catch (_) {}
          },
          onError: (Object _, StackTrace __) {},
        ),
      );
      rethrow;
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

  static Future<http.StreamedResponse> _sendResponse(
    http.Client client,
    http.BaseRequest request,
    VerifiedUpdateCancellation? cancellation, {
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

  static Stream<List<int>> _cancellableStream(
    Stream<List<int>> source,
    VerifiedUpdateCancellation? cancellation, {
    required Stopwatch attemptClock,
    required Duration timeout,
  }) async* {
    final iterator = StreamIterator<List<int>>(source);
    try {
      while (await _awaitWithCancellation(
        iterator
            .moveNext()
            .timeout(_remainingAttemptTime(attemptClock, timeout)),
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
    if (remaining <= Duration.zero) {
      throw TimeoutException('更新下载超时');
    }
    return remaining;
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
    });
  }
}

enum _VerifiedPublicationOutcome { committed, reused }

class _VerifiedUpdatePublicationLease {
  _VerifiedUpdatePublicationLease({
    required this.isolateLockName,
    required this.receivePort,
    required this.subscription,
    required this.lockFile,
  });

  final String isolateLockName;
  final ReceivePort receivePort;
  final StreamSubscription<Object?> subscription;
  final RandomAccessFile lockFile;

  Future<void> release() async {
    try {
      await lockFile.unlock();
    } catch (_) {}
    try {
      await lockFile.close();
    } catch (_) {}
    if (IsolateNameServer.lookupPortByName(isolateLockName) ==
        receivePort.sendPort) {
      IsolateNameServer.removePortNameMapping(isolateLockName);
    }
    try {
      await subscription.cancel();
    } catch (_) {}
    receivePort.close();
  }
}

class _UpdateDigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

part of 'update_service.dart';

// Recovery runs before the network request and scans a user-writable
// directory, so every dimension needs a hard upper bound.
const int _recoveryDirectoryEntryLimit = 4096;
const int _recoveryCandidateLimit = 16;
const int _recoveryTotalByteLimit =
    2 * SharedUpdateService.maxDesktopUpdateBytes;
const int _recoveryHashChunkBytes = 64 * 1024;
const Duration _publicationLockTimeout = Duration(seconds: 15);
const Duration _publicationLockRetryDelay = Duration(
  milliseconds: 25,
);
const Duration _publicationLeaseProbeTimeout = Duration(seconds: 5);
int? _recoveryDirectoryEntryLimitForTesting;
void Function(VerifiedUpdateRecoveryTestStep)? _recoveryStepForTesting;
FutureOr<void> Function(VerifiedUpdatePublicationTestStep)?
    _publicationStepForTesting;

Future<_VerifiedPublicationOutcome> _publishVerifiedFileLocked({
  required File temporary,
  required File destination,
  required String expectedSha256,
  required int expectedLength,
  required int maxBytes,
  VerifiedUpdateCancellation? cancellation,
  VerifiedUpdateFilePublisher? filePublisher,
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
  final published = await _publishFileNoReplace(
    source: temporary,
    destination: destination,
    cancellation: cancellation,
    filePublisher: filePublisher,
  );
  if (!published) {
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
    // Publication is the irreversible commit point. Once the publisher has
    // returned success, finish verification and acknowledge the destination
    // even if the user pressed Cancel while the native call was in flight.
    cancellation: null,
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

/// Atomically publishes the verified staging file without replacing an
/// existing destination. Cancellation is honored until the publisher starts;
/// after that point its result must be reconciled before returning to the UI.
Future<bool> _publishFileNoReplace({
  required File source,
  required File destination,
  required VerifiedUpdateCancellation? cancellation,
  required VerifiedUpdateFilePublisher? filePublisher,
}) async {
  cancellation?.throwIfCancelled();
  if (filePublisher != null) {
    try {
      await filePublisher(source, destination);
      return true;
    } catch (_) {
      final destinationType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (destinationType != FileSystemEntityType.notFound) return false;
      cancellation?.throwIfCancelled();
      rethrow;
    }
  }
  late final ProcessResult result;
  if (Platform.isWindows) {
    throw UnsupportedError(
      'Windows verified update publication requires a native publisher',
    );
  }
  result = await Process.run(
    '/bin/ln',
    <String>[source.absolute.path, destination.absolute.path],
  );
  if (result.exitCode == 0) return true;
  final destinationType = await FileSystemEntity.type(
    destination.path,
    followLinks: false,
  );
  if (destinationType != FileSystemEntityType.notFound) return false;
  cancellation?.throwIfCancelled();
  final details = result.stderr.toString().trim();
  throw FileSystemException(
    details.isEmpty ? '无法原子发布更新文件' : details,
    destination.path,
  );
}

Future<bool> _recoverInterruptedPublicationLocked(
  File destination, {
  required String expectedSha256,
  required int maxBytes,
  VerifiedUpdateCancellation? cancellation,
  VerifiedUpdateFilePublisher? filePublisher,
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
      if (stat.size < 0 || stat.size > maxBytes) continue;

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
        backups.removeLast();
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

  if (destinationType == FileSystemEntityType.file) {
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
        filePublisher: filePublisher,
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

  // Directory candidates are read-only recovery inputs, not proof of app
  // ownership. Preserve every source path even after a successful recovery;
  // only staging files created exclusively by this call may be deleted.
  return recovered;
}

Future<bool> _verifiedFileMatches(
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

Future<T> _withPublicationLock<T>(
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

Future<_VerifiedUpdatePublicationLease> _acquirePublicationLock(
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

Future<RandomAccessFile> _acquirePublicationFileLock(
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

Future<void> _waitForIsolatePublicationLease(
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

Future<void> _publicationLockDelay(
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

Future<void> _notifyPublicationStep(
  VerifiedUpdatePublicationTestStep step,
) async {
  final callback = _publicationStepForTesting;
  if (callback != null) await callback(step);
}

Future<({File? verifiedCopy, int bytesRead})> _createVerifiedRecoveryCopy({
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

Future<File> _createUniqueRecoveryStagingFile(
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

Future<void> _deleteRecoveryBackupBestEffort(
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

Future<RandomAccessFile> _openRecoveryFile(
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

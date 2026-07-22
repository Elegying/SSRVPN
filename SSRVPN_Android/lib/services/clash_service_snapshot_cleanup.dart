part of 'clash_service.dart';

typedef _SnapshotCleanupMarker = ({
  bool committed,
  Set<String> fileNames,
  bool generationBound,
  bool deferredUntilReplacement,
  bool replacementPrepared,
  String? replacementBaselineGeneration,
  String? replacementFileName,
  String? expectedNativeGeneration,
});

extension AndroidSnapshotCleanup on ClashService {
  Future<String> _writeConfigSnapshot(String config) async {
    final revision = ++_configRevision;
    final path = '$configDir/config-'
        '${DateTime.now().microsecondsSinceEpoch}-$revision.yaml';
    final absolutePath = File(path).absolute.path;
    _preparedConfigPaths.add(absolutePath);
    try {
      await writeStringAtomically(File(absolutePath), config);
      return absolutePath;
    } catch (_) {
      _preparedConfigPaths.remove(absolutePath);
      rethrow;
    }
  }

  /// Invalidates a disconnected quick-start snapshot before a setting that
  /// changes generated configuration is committed. This prevents the Android
  /// tile from replaying an older mode, rule set, or preferred node.
  Future<void> _invalidateIdleNativeConnectionSnapshot() async {
    if (isRunning) {
      throw StateError('VPN 已在连接，不能清理快速启动信息');
    }
    final cleared = await clearNativeConnectionSnapshot();
    if (!cleared || isRunning) {
      throw StateError('快速启动信息已被新的连接更新，请重试');
    }
  }

  Future<T> _serializeNativeSnapshotOperation<T>(
    Future<T> Function() operation,
  ) {
    _nativeSnapshotOperationCount += 1;
    Future<T> run() async {
      try {
        return await operation();
      } finally {
        _nativeSnapshotOperationCount -= 1;
      }
    }

    final result = _nativeSnapshotOperationTail.then((_) => run());
    _nativeSnapshotOperationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<bool> clearNativeConnectionSnapshot() =>
      _serializeNativeSnapshotOperation(() async {
        final expectedGeneration = await _readNativeSnapshotGeneration();
        final fileNames = await _collectSnapshotConfigFileNames();
        await _writeSnapshotCleanupMarker(
          committed: false,
          fileNames: fileNames,
          expectedNativeGeneration: expectedGeneration,
        );
        final cleared = await ClashService._channel.invokeMethod<bool>(
          'clearConnectionSnapshot',
          {'expectedGeneration': expectedGeneration},
        );
        await _writeSnapshotCleanupMarker(
          committed: true,
          fileNames: fileNames,
          expectedNativeGeneration: expectedGeneration,
        );
        if (cleared == true &&
            _nativeSnapshotGeneration == expectedGeneration) {
          _nativeSnapshotConfigPath = null;
          _nativeSnapshotGeneration = null;
        }
        if (!isRunning) await _completePendingSnapshotFileCleanup();
        return cleared == true;
      });

  Future<void> _pruneVersionedConfigs(Set<String> keepPaths) async {
    final directory = Directory(configDir);
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      final absolutePath = File(entity.path).absolute.path;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('config-') || !name.endsWith('.yaml')) continue;
      if (keepPaths.contains(absolutePath) ||
          _preparedConfigPaths.contains(absolutePath)) {
        continue;
      }
      if (await FileSystemEntity.type(absolutePath, followLinks: false) ==
              FileSystemEntityType.file &&
          !_preparedConfigPaths.contains(absolutePath)) {
        await File(absolutePath).delete();
      }
    }
  }

  Future<void> discardPreparedConfig(String path) async {
    final absolutePath = File(path).absolute.path;
    _preparedConfigPaths.remove(absolutePath);
    if (absolutePath == _runningConfigPath ||
        absolutePath == _nativeSnapshotConfigPath) {
      return;
    }
    final file = File(absolutePath);
    final name = file.uri.pathSegments.last;
    if (!name.startsWith('config-') || !name.endsWith('.yaml')) return;
    if (file.parent.path != Directory(configDir).absolute.path) return;
    if (await FileSystemEntity.type(absolutePath, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }

  File get _snapshotCleanupMarker => File(
        '$configDir${Platform.pathSeparator}.snapshot-cleanup.pending',
      );

  bool _isSnapshotConfigFileName(String name) =>
      name == 'config.yaml' ||
      (name.startsWith('config-') && name.endsWith('.yaml'));

  Future<Set<String>> _collectSnapshotConfigFileNames() async {
    final directory = Directory(configDir);
    if (!await directory.exists()) return const <String>{};
    final names = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (!_isSnapshotConfigFileName(name)) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        names.add(name);
      }
    }
    return names;
  }

  Future<void> _writeSnapshotCleanupMarker({
    required bool committed,
    required Set<String> fileNames,
    required String? expectedNativeGeneration,
    bool deferredUntilReplacement = false,
    bool replacementPrepared = false,
    String? replacementBaselineGeneration,
    String? replacementFileName,
  }) async {
    final marker = _snapshotCleanupMarker;
    final temporary = File('${marker.path}.tmp');
    final sortedNames = fileNames.toList()..sort();
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 4,
          'committed': committed,
          'files': sortedNames,
          'expectedNativeGeneration': expectedNativeGeneration,
          'deferredUntilReplacement': deferredUntilReplacement,
          'replacementPrepared': replacementPrepared,
          'replacementBaselineGeneration': replacementBaselineGeneration,
          'replacementFileName': replacementFileName,
        }),
        flush: true,
      );
      await temporary.rename(marker.path);
    } catch (_) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<_SnapshotCleanupMarker?> _readSnapshotCleanupMarker() async {
    final marker = _snapshotCleanupMarker;
    if (!await marker.exists()) return null;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map<String, dynamic> ||
          (decoded['version'] != 1 &&
              decoded['version'] != 2 &&
              decoded['version'] != 3 &&
              decoded['version'] != 4) ||
          decoded['committed'] is! bool ||
          decoded['files'] is! List) {
        throw const FormatException('invalid snapshot cleanup marker');
      }
      final names = <String>{};
      for (final value in decoded['files'] as List) {
        if (value is! String || !_isSnapshotConfigFileName(value)) {
          throw const FormatException('unsafe snapshot cleanup path');
        }
        names.add(value);
      }
      final version = decoded['version'] as int;
      final expectedGeneration = decoded['expectedNativeGeneration'];
      if (version >= 2 &&
          expectedGeneration != null &&
          (expectedGeneration is! String || expectedGeneration.isEmpty)) {
        throw const FormatException('invalid native snapshot generation');
      }
      final deferred = decoded['deferredUntilReplacement'];
      if (version == 3 && deferred is! bool) {
        throw const FormatException('invalid deferred cleanup state');
      }
      final replacementPrepared = decoded['replacementPrepared'];
      final replacementBaseline = decoded['replacementBaselineGeneration'];
      final replacementFile = decoded['replacementFileName'];
      if (version == 4 && (deferred is! bool || replacementPrepared is! bool)) {
        throw const FormatException('invalid replacement cleanup state');
      }
      if (version == 4 && replacementPrepared == true) {
        if ((replacementBaseline != null && replacementBaseline is! String) ||
            replacementFile is! String ||
            !_isSnapshotConfigFileName(replacementFile)) {
          throw const FormatException('invalid replacement cleanup intent');
        }
      } else if (version == 4 &&
          (replacementBaseline != null || replacementFile != null)) {
        throw const FormatException('orphaned replacement cleanup fields');
      }
      return (
        committed: decoded['committed'] as bool,
        fileNames: names,
        generationBound: version >= 2,
        deferredUntilReplacement: version >= 3 && deferred == true,
        replacementPrepared: version == 4 && replacementPrepared == true,
        replacementBaselineGeneration:
            version == 4 ? replacementBaseline as String? : null,
        replacementFileName: version == 4 ? replacementFile as String? : null,
        expectedNativeGeneration:
            version >= 2 ? expectedGeneration as String? : null,
      );
    } catch (error) {
      log('快照配置清理标记无效，已安全保留文件: $error');
      return null;
    }
  }

  Future<void> resumePendingNativeSnapshotCleanup() =>
      _serializeNativeSnapshotOperation(_resumePendingNativeSnapshotCleanup);

  Future<void> _resumePendingNativeSnapshotCleanup() async {
    var marker = await _readSnapshotCleanupMarker();
    if (marker == null) return;
    if (!marker.generationBound) {
      marker = await _retireUnboundLegacySnapshotCleanup(marker);
    }
    if (marker.deferredUntilReplacement) {
      try {
        marker = await _resolveCommittedDeferredReplacement(marker);
      } catch (error) {
        log('恢复旧版快照配置延迟清理失败，保留候选文件: $error');
        return;
      }
      if (marker.deferredUntilReplacement) return;
    }
    if (!marker.committed) {
      try {
        final cleared = await ClashService._channel.invokeMethod<bool>(
          'clearConnectionSnapshot',
          {'expectedGeneration': marker.expectedNativeGeneration},
        );
        await _writeSnapshotCleanupMarker(
          committed: true,
          fileNames: marker.fileNames,
          expectedNativeGeneration: marker.expectedNativeGeneration,
        );
        if (cleared == true &&
            _nativeSnapshotGeneration == marker.expectedNativeGeneration) {
          _nativeSnapshotConfigPath = null;
          _nativeSnapshotGeneration = null;
        }
        marker = (
          committed: true,
          fileNames: marker.fileNames,
          generationBound: true,
          deferredUntilReplacement: false,
          replacementPrepared: false,
          replacementBaselineGeneration: null,
          replacementFileName: null,
          expectedNativeGeneration: marker.expectedNativeGeneration,
        );
      } catch (error) {
        log('恢复原生快照清理事务失败，保留待清理配置: $error');
        return;
      }
    }
    await _completePendingSnapshotFileCleanup();
  }

  Future<void> _reconcileSnapshotCleanupAfterCommit(
    String snapshotPath,
  ) async {
    final pending = await _readSnapshotCleanupMarker();
    if (pending == null) return;
    final remaining = Set<String>.of(pending.fileNames);
    final snapshot = File(snapshotPath).absolute;
    if (snapshot.parent.path == Directory(configDir).absolute.path) {
      remaining.remove(snapshot.uri.pathSegments.last);
    }
    // A successful syncSettings replaces whichever native snapshot existed
    // before it. Any older prepared clear must never replay against this new
    // generation, while its exact old files remain eligible for later cleanup.
    await _writeSnapshotCleanupMarker(
      committed: true,
      fileNames: remaining,
      expectedNativeGeneration: pending.expectedNativeGeneration,
    );
  }

  Future<String?> _readNativeSnapshotGeneration() =>
      ClashService._channel.invokeMethod<String>(
        'getConnectionSnapshotGeneration',
      );

  Future<void> _preparePendingSnapshotCleanupForReplacement(
    String snapshotPath,
  ) async {
    var pending = await _readSnapshotCleanupMarker();
    if (pending == null) return;
    if (!pending.generationBound) {
      pending = await _retireUnboundLegacySnapshotCleanup(pending);
    }
    if (!pending.deferredUntilReplacement) return;

    pending = await _resolveCommittedDeferredReplacement(pending);
    if (!pending.deferredUntilReplacement) return;

    final snapshot = File(snapshotPath).absolute;
    if (snapshot.parent.path != Directory(configDir).absolute.path) {
      throw StateError('替代快照配置不在受管目录');
    }
    final snapshotName = snapshot.uri.pathSegments.last;
    if (!_isSnapshotConfigFileName(snapshotName)) {
      throw StateError('替代快照配置名称无效');
    }
    final baselineGeneration = await _readNativeSnapshotGeneration();
    await _writeSnapshotCleanupMarker(
      committed: true,
      fileNames: pending.fileNames,
      expectedNativeGeneration: null,
      deferredUntilReplacement: true,
      replacementPrepared: true,
      replacementBaselineGeneration: baselineGeneration,
      replacementFileName: snapshotName,
    );
  }

  Future<_SnapshotCleanupMarker> _resolveCommittedDeferredReplacement(
    _SnapshotCleanupMarker pending,
  ) async {
    if (!pending.deferredUntilReplacement || !pending.replacementPrepared) {
      return pending;
    }
    final currentGeneration = await _readNativeSnapshotGeneration();
    if (currentGeneration == pending.replacementBaselineGeneration) {
      return pending;
    }
    final remaining = Set<String>.of(pending.fileNames)
      ..remove(pending.replacementFileName);
    await _writeSnapshotCleanupMarker(
      committed: true,
      fileNames: remaining,
      expectedNativeGeneration: null,
    );
    return (
      committed: true,
      fileNames: remaining,
      generationBound: true,
      deferredUntilReplacement: false,
      replacementPrepared: false,
      replacementBaselineGeneration: null,
      replacementFileName: null,
      expectedNativeGeneration: null,
    );
  }

  Future<_SnapshotCleanupMarker> _retireUnboundLegacySnapshotCleanup(
    _SnapshotCleanupMarker pending,
  ) async {
    // A v1 marker carries no native generation. Its committed bit proves only
    // that the old clear reached its own commit point; it cannot prove that a
    // later replacement did not reuse one of the recorded files. After an
    // upgrade there is no safe way to tell whether the current legacy snapshot
    // belongs to this clear or to a later replacement that committed before a
    // crash. Defer the exact candidates without touching either snapshot or
    // files; a later successful replacement excludes its own path and makes
    // only the remaining candidates eligible for cleanup.
    await _writeSnapshotCleanupMarker(
      committed: true,
      fileNames: pending.fileNames,
      expectedNativeGeneration: null,
      deferredUntilReplacement: true,
    );
    return (
      committed: true,
      fileNames: pending.fileNames,
      generationBound: true,
      deferredUntilReplacement: true,
      replacementPrepared: false,
      replacementBaselineGeneration: null,
      replacementFileName: null,
      expectedNativeGeneration: null,
    );
  }

  Future<void> _completePendingSnapshotFileCleanup() async {
    final pending = await _readSnapshotCleanupMarker();
    if (pending == null ||
        !pending.committed ||
        pending.deferredUntilReplacement) {
      return;
    }
    final nativeState = await _queryNativeConnectionState();
    if (nativeState == null) {
      log('无法确认原生 VPN 恢复预留配置，延后清理');
      return;
    }
    _nativeSessionProtocolAvailable = true;
    _runningConfigPath = nativeState.protectedConfigPath;
    _nativeSessionGeneration = nativeState.sessionGeneration;
    if (nativeState.transitioning) {
      log('原生 VPN 正在启动或恢复，延后快照配置清理');
      return;
    }
    final protectedName = nativeState.protectedConfigPath == null
        ? null
        : File(nativeState.protectedConfigPath!).uri.pathSegments.last;
    final remaining = <String>{};
    try {
      for (final name in pending.fileNames) {
        if (name == protectedName) {
          remaining.add(name);
          continue;
        }
        final entity = File(
          '$configDir${Platform.pathSeparator}$name',
        );
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.file ||
            type == FileSystemEntityType.link) {
          await entity.delete();
        }
      }
      if (remaining.isEmpty) {
        await _snapshotCleanupMarker.delete();
        if (nativeState.protectedConfigPath == null) {
          _runningConfigPath = null;
        }
      } else {
        await _writeSnapshotCleanupMarker(
          committed: true,
          fileNames: remaining,
          expectedNativeGeneration: pending.expectedNativeGeneration,
        );
      }
    } catch (error) {
      log('快照配置延迟清理失败，保留事务标记以便重试: $error');
    }
  }
}

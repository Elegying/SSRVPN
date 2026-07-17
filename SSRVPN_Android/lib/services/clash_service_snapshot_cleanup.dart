part of 'clash_service.dart';

typedef _SnapshotCleanupMarker = ({
  bool committed,
  Set<String> fileNames,
});

extension AndroidSnapshotCleanup on ClashService {
  Future<void> clearNativeConnectionSnapshot() =>
      _serializeNativeSnapshotOperation(() async {
        final fileNames = await _collectSnapshotConfigFileNames();
        await _writeSnapshotCleanupMarker(
          committed: false,
          fileNames: fileNames,
        );
        await ClashService._channel.invokeMethod('clearConnectionSnapshot');
        await _writeSnapshotCleanupMarker(
          committed: true,
          fileNames: fileNames,
        );
        if (!isRunning) await _completePendingSnapshotFileCleanup();
      });

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
  }) async {
    final marker = _snapshotCleanupMarker;
    final temporary = File('${marker.path}.tmp');
    final sortedNames = fileNames.toList()..sort();
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'committed': committed,
          'files': sortedNames,
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
          decoded['version'] != 1 ||
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
      return (
        committed: decoded['committed'] as bool,
        fileNames: names,
      );
    } catch (error) {
      log('快照配置清理标记无效，已安全保留文件: $error');
      return null;
    }
  }

  Future<void> _resumePendingSnapshotFileCleanup() async {
    var marker = await _readSnapshotCleanupMarker();
    if (marker == null) return;
    if (!marker.committed) {
      try {
        await ClashService._channel.invokeMethod('clearConnectionSnapshot');
        await _writeSnapshotCleanupMarker(
          committed: true,
          fileNames: marker.fileNames,
        );
        marker = (committed: true, fileNames: marker.fileNames);
      } catch (error) {
        log('恢复原生快照清理事务失败，保留待清理配置: $error');
        return;
      }
    }
    final nativeRunning = await _queryNativeRunningState();
    if (nativeRunning == false) {
      await _completePendingSnapshotFileCleanup();
    }
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
    );
  }

  Future<void> _completePendingSnapshotFileCleanup() async {
    final pending = await _readSnapshotCleanupMarker();
    if (pending == null || !pending.committed) return;
    _runningConfigPath = null;
    try {
      for (final name in pending.fileNames) {
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
      await _snapshotCleanupMarker.delete();
    } catch (error) {
      log('快照配置延迟清理失败，保留事务标记以便重试: $error');
    }
  }
}

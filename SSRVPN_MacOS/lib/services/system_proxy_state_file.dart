part of 'system_proxy_service.dart';

// Recovery file checks stay in the service library to retain ownership semantics.
extension _MacSystemProxyStateFile on SystemProxyService {
  Future<_ProxyStateFileStatus> _inspectStateFile(File file) async {
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return _ProxyStateFileStatus.missing;
      }
      if (type != FileSystemEntityType.file) {
        _lastError = '代理恢复状态路径不是安全的普通文件，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }

      final stat = await file.stat();
      final typeAfterStat = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      const fileTypeMask = 0xF000;
      const regularFileType = 0x8000;
      if (typeAfterStat != FileSystemEntityType.file ||
          stat.mode & fileTypeMask != regularFileType) {
        _lastError = '代理恢复状态路径不是安全的普通文件，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      if (stat.size > SystemProxyService._maxStateFileBytes) {
        _lastError = '代理恢复状态超过 1 MiB 安全上限，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      if (stat.mode & SystemProxyService._groupOrOtherWriteMask != 0) {
        _lastError = '代理恢复状态文件为 group/other 可写，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      return _ProxyStateFileStatus.safe;
    } catch (error) {
      _lastError = '无法安全检查代理恢复状态，已保留现场: $error';
      return _ProxyStateFileStatus.unsafe;
    }
  }

  Future<bool> _deleteStateFileIfUnchanged(
    File file,
    String expectedContents,
  ) async {
    try {
      if (await _inspectStateFile(file) != _ProxyStateFileStatus.safe) {
        _lastError ??= '代理恢复快照身份已变化，已保留现场';
        return false;
      }
      final currentContents = await file.readAsString();
      final typeBeforeDelete = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (typeBeforeDelete != FileSystemEntityType.file ||
          currentContents != expectedContents) {
        _lastError = '代理恢复快照身份已变化，已保留现场';
        return false;
      }

      await file.delete();
      final typeAfterDelete = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (typeAfterDelete != FileSystemEntityType.notFound) {
        _lastError = '代理恢复快照删除后路径仍存在，已保留现场';
        return false;
      }
      return true;
    } catch (error) {
      _lastError = '无法安全删除代理恢复快照，已保留现场: $error';
      return false;
    }
  }

  Future<void> _writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }
}

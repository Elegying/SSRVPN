part of 'settings_service.dart';

typedef _OpenDirectoryNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDirectoryDart = int Function(Pointer<Utf8>, int);
typedef _FileDescriptorNative = Int32 Function(Int32);
typedef _FileDescriptorDart = int Function(int);

/// Owns the permission and crash-consistency rules for private macOS files.
class _MacosPrivateFileStore {
  _MacosPrivateFileStore(this._dataDirectory);

  final String Function() _dataDirectory;

  static final _libc = DynamicLibrary.process();
  static final _openDirectory =
      _libc.lookupFunction<_OpenDirectoryNative, _OpenDirectoryDart>('open');
  static final _fsync =
      _libc.lookupFunction<_FileDescriptorNative, _FileDescriptorDart>('fsync');
  static final _close =
      _libc.lookupFunction<_FileDescriptorNative, _FileDescriptorDart>('close');

  String get _dataDir => _dataDirectory();
  String get _apiSecretPath => '$_dataDir${Platform.pathSeparator}.api-secret';

  Future<String?> readApiSecret() async {
    final type =
        await FileSystemEntity.type(_apiSecretPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'API secret path must be a regular file',
        _apiSecretPath,
      );
    }

    final file = File(_apiSecretPath);
    var stat = await file.stat();
    if ((stat.mode & 0x1ff) != 0x180) {
      await _chmod('600', file.path);
      stat = await file.stat();
      if ((stat.mode & 0x1ff) != 0x180) {
        throw FileSystemException(
          'API secret permissions must be 0600',
          file.path,
        );
      }
    }

    final value = await file.readAsString();
    if (value.isEmpty) return null;
    if (value.length > 4096) {
      throw const FormatException('API secret file is unexpectedly large');
    }
    return value;
  }

  Future<void> writeApiSecret(String value) async {
    if (value.isEmpty || value.length > 4096) {
      throw ArgumentError.value(value.length, 'value', 'invalid API secret');
    }

    await ensurePrivateDataDirectory(_dataDir);
    final temp = File(
      '$_apiSecretPath.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    RandomAccessFile? handle;
    try {
      await temp.create(exclusive: true);
      await _chmod('600', temp.path);
      handle = await temp.open(mode: FileMode.writeOnly);
      await handle.writeString(value);
      await handle.flush();
      await handle.close();
      handle = null;
      await temp.rename(_apiSecretPath);
      syncDataDirectory();

      final stat = await File(_apiSecretPath).stat();
      if ((stat.mode & 0x1ff) != 0x180) {
        throw FileSystemException(
          'API secret permissions must be 0600',
          _apiSecretPath,
        );
      }
    } finally {
      await handle?.close();
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> removeApiSecretTemporaryFiles() async {
    final directoryType =
        await FileSystemEntity.type(_dataDir, followLinks: false);
    if (directoryType == FileSystemEntityType.notFound) return;
    if (directoryType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'SSRVPN data path must be a real directory',
        _dataDir,
      );
    }

    await for (final entry in Directory(_dataDir).list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('.api-secret.tmp.')) continue;
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.link) {
        throw FileSystemException(
          'API secret temporary path must be a file',
          entry.path,
        );
      }
      await File(entry.path).delete();
    }
  }

  Future<void> ensurePrivateDataDirectory(String path) async {
    var type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(path).create(recursive: true);
      type = await FileSystemEntity.type(path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'SSRVPN data path must be a real directory',
        path,
      );
    }
    await _chmod('700', path);
  }

  void syncDataDirectory() {
    if (!Platform.isMacOS) return;
    final path = _dataDir.toNativeUtf8(allocator: calloc);
    var descriptor = -1;
    try {
      descriptor = _openDirectory(path, 0);
      if (descriptor < 0) {
        throw FileSystemException(
          'failed to open the data directory for fsync',
          _dataDir,
        );
      }
      if (_fsync(descriptor) != 0) {
        throw FileSystemException(
          'failed to fsync the data directory',
          _dataDir,
        );
      }
    } finally {
      if (descriptor >= 0) _close(descriptor);
      calloc.free(path);
    }
  }

  Future<void> _chmod(String mode, String path) async {
    final result = await Process.run('/bin/chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'chmod $mode failed: ${result.stderr}',
        path,
      );
    }
  }
}

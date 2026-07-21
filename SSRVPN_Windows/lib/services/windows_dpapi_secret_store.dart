import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

typedef SecretCipher = Future<Uint8List> Function(Uint8List input);
typedef AtomicFileReplace = Future<void> Function(
  File source,
  File destination,
);

/// Signals that an existing DPAPI envelope must be preserved for recovery but
/// cannot be used by the current Windows account.
class WindowsApiSecretRecoveryRequired implements Exception {
  const WindowsApiSecretRecoveryRequired(this.path);

  static const marker = 'WINDOWS_DPAPI_RECOVERY_REQUIRED';
  final String path;

  @override
  String toString() => '$marker: 当前 Windows 账户无法解密本机 API secret；密文已保留在 $path';
}

/// Stores the Mihomo API secret in a dedicated, current-user DPAPI envelope.
///
/// Encrypted bytes are flushed to a same-directory temporary file before
/// [MoveFileEx] atomically replaces the durable value. A failed replacement
/// therefore leaves the previous secret readable after a crash or power loss.
class WindowsDpapiSecretStore {
  WindowsDpapiSecretStore(
    this.dataDirectory, {
    SecretCipher? protect,
    SecretCipher? unprotect,
    AtomicFileReplace? replaceFile,
    AtomicFileReplace? isolateFile,
  })  : _protect = protect ?? _protectWithDpapi,
        _unprotect = unprotect ?? _unprotectWithDpapi,
        _replaceFile = replaceFile ?? _replaceWithMoveFileEx,
        _isolateFile = isolateFile ?? _moveExclusivelyWithMoveFileEx;

  static const _fileName = '.api-secret.dpapi';
  static const _maxPlainTextBytes = 4096;
  static const _maxEncryptedBytes = 64 * 1024;
  static const _cryptProtectUiForbidden = 0x1;

  final String dataDirectory;
  final SecretCipher _protect;
  final SecretCipher _unprotect;
  final AtomicFileReplace _replaceFile;
  final AtomicFileReplace _isolateFile;

  String get _path => '$dataDirectory${Platform.pathSeparator}$_fileName';

  Future<String?> read() async {
    final directoryType = await FileSystemEntity.type(
      dataDirectory,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.notFound) return null;
    if (directoryType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Windows secret data directory must be a real directory',
        dataDirectory,
      );
    }
    await _removeTemporaryFiles();

    final type = await FileSystemEntity.type(_path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Windows secret storage must be a regular file',
        _path,
      );
    }

    final file = File(_path);
    final length = await file.length();
    if (length <= 0 || length > _maxEncryptedBytes) {
      throw WindowsApiSecretRecoveryRequired(_path);
    }

    final encrypted = await file.readAsBytes();
    try {
      final plainText = await _unprotect(encrypted);
      if (plainText.isEmpty || plainText.length > _maxPlainTextBytes) {
        throw const FormatException('Invalid Windows API secret length');
      }

      final secret = utf8.decode(plainText, allowMalformed: false);
      if (secret.isEmpty) {
        throw const FormatException('Windows API secret is empty');
      }
      return secret;
    } on WindowsApiSecretRecoveryRequired {
      rethrow;
    } on WindowsException {
      throw WindowsApiSecretRecoveryRequired(_path);
    } on FormatException {
      throw WindowsApiSecretRecoveryRequired(_path);
    }
  }

  Future<void> write(String value) async {
    final plainText = Uint8List.fromList(utf8.encode(value));
    if (plainText.isEmpty || plainText.length > _maxPlainTextBytes) {
      throw ArgumentError.value(
        plainText.length,
        'valueLength',
        'Invalid API secret length',
      );
    }

    await _ensureRealDataDirectory();
    await _removeTemporaryFiles();
    final destinationType =
        await FileSystemEntity.type(_path, followLinks: false);
    if (destinationType != FileSystemEntityType.notFound &&
        destinationType != FileSystemEntityType.file) {
      throw FileSystemException(
        'Windows secret storage must be a regular file',
        _path,
      );
    }

    final encrypted = await _protect(plainText);
    if (encrypted.isEmpty || encrypted.length > _maxEncryptedBytes) {
      throw const FormatException('Invalid Windows secret envelope length');
    }

    final randomSuffix = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final temp = File(
      '$_path.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}.$randomSuffix',
    );
    RandomAccessFile? handle;
    try {
      await temp.create(exclusive: true);
      handle = await temp.open(mode: FileMode.writeOnly);
      await handle.writeFrom(encrypted);
      await handle.flush();
      await handle.close();
      handle = null;
      await _replaceFile(temp, File(_path));
    } finally {
      await handle?.close();
      final tempType =
          await FileSystemEntity.type(temp.path, followLinks: false);
      if (tempType == FileSystemEntityType.file ||
          tempType == FileSystemEntityType.link) {
        await temp.delete();
      }
    }
  }

  /// Atomically retires an unreadable DPAPI envelope without deleting it.
  /// A later SettingsService initialization can then generate a fresh secret.
  Future<String?> isolateUnreadableEnvelope() async {
    await _ensureRealDataDirectory();
    await _removeTemporaryFiles();
    final sourceType = await FileSystemEntity.type(_path, followLinks: false);
    if (sourceType == FileSystemEntityType.notFound) return null;
    if (sourceType != FileSystemEntityType.file) {
      throw FileSystemException(
        'Windows secret storage must be a regular file',
        _path,
      );
    }

    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final randomSuffix = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final isolated = File(
      '$_path.unreadable.$stamp.$pid.$randomSuffix',
    );
    if (await FileSystemEntity.type(isolated.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Windows secret recovery destination already exists',
        isolated.path,
      );
    }

    await _isolateFile(File(_path), isolated);
    final sourceAfter = await FileSystemEntity.type(_path, followLinks: false);
    final isolatedAfter =
        await FileSystemEntity.type(isolated.path, followLinks: false);
    if (sourceAfter != FileSystemEntityType.notFound ||
        isolatedAfter != FileSystemEntityType.file) {
      throw FileSystemException(
        'Windows secret recovery isolation could not be verified',
        isolated.path,
      );
    }
    return isolated.path;
  }

  Future<void> _ensureRealDataDirectory() async {
    var type = await FileSystemEntity.type(
      dataDirectory,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await Directory(dataDirectory).create(recursive: true);
      type = await FileSystemEntity.type(
        dataDirectory,
        followLinks: false,
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Windows secret data directory must be a real directory',
        dataDirectory,
      );
    }
  }

  Future<void> _removeTemporaryFiles() async {
    await for (final entry
        in Directory(dataDirectory).list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('$_fileName.tmp.')) continue;
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.link) {
        throw FileSystemException(
          'Windows secret temporary path must be a file',
          entry.path,
        );
      }
      await File(entry.path).delete();
    }
  }

  static Future<void> _replaceWithMoveFileEx(
    File source,
    File destination,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('DPAPI secret storage is Windows-only');
    }

    final sourcePath = source.path.toNativeUtf16(allocator: calloc);
    final destinationPath = destination.path.toNativeUtf16(allocator: calloc);
    try {
      final result = MoveFileEx(
        PCWSTR(sourcePath),
        PCWSTR(destinationPath),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
      );
      if (!result.value) {
        throw WindowsException(
          result.error.toHRESULT(),
          message: 'Failed to atomically replace the Windows API secret',
        );
      }
    } finally {
      calloc.free(sourcePath);
      calloc.free(destinationPath);
    }
  }

  static Future<void> _moveExclusivelyWithMoveFileEx(
    File source,
    File destination,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('DPAPI secret storage is Windows-only');
    }

    final sourcePath = source.path.toNativeUtf16(allocator: calloc);
    final destinationPath = destination.path.toNativeUtf16(allocator: calloc);
    try {
      final result = MoveFileEx(
        PCWSTR(sourcePath),
        PCWSTR(destinationPath),
        MOVEFILE_WRITE_THROUGH,
      );
      if (!result.value) {
        throw WindowsException(
          result.error.toHRESULT(),
          message: 'Failed to isolate the unreadable Windows API secret',
        );
      }
    } finally {
      calloc.free(sourcePath);
      calloc.free(destinationPath);
    }
  }

  static Future<Uint8List> _protectWithDpapi(Uint8List plainText) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('DPAPI secret storage is Windows-only');
    }

    return using((arena) {
      final inputBytes = arena<Uint8>(plainText.length);
      inputBytes.asTypedList(plainText.length).setAll(0, plainText);
      final input = arena<CRYPT_INTEGER_BLOB>()
        ..ref.cbData = plainText.length
        ..ref.pbData = inputBytes;
      final output = arena<CRYPT_INTEGER_BLOB>();

      final result = CryptProtectData(
        input,
        null,
        null,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      if (!result.value) {
        throw WindowsException(
          result.error.toHRESULT(),
          message: 'CryptProtectData failed for the Windows API secret',
        );
      }
      return _copyAndFreeDpapiOutput(output, 'CryptProtectData');
    });
  }

  static Future<Uint8List> _unprotectWithDpapi(Uint8List encrypted) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('DPAPI secret storage is Windows-only');
    }

    return using((arena) {
      final inputBytes = arena<Uint8>(encrypted.length);
      inputBytes.asTypedList(encrypted.length).setAll(0, encrypted);
      final input = arena<CRYPT_INTEGER_BLOB>()
        ..ref.cbData = encrypted.length
        ..ref.pbData = inputBytes;
      final output = arena<CRYPT_INTEGER_BLOB>();

      final result = CryptUnprotectData(
        input,
        null,
        null,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      if (!result.value) {
        throw WindowsException(
          result.error.toHRESULT(),
          message: 'CryptUnprotectData failed for the Windows API secret',
        );
      }
      return _copyAndFreeDpapiOutput(output, 'CryptUnprotectData');
    });
  }

  static Uint8List _copyAndFreeDpapiOutput(
    Pointer<CRYPT_INTEGER_BLOB> output,
    String operation,
  ) {
    final data = output.ref.pbData;
    final length = output.ref.cbData;
    if (data.address == 0 || length <= 0 || length > _maxEncryptedBytes) {
      if (data.address != 0) LocalFree(HLOCAL(data.cast()));
      throw FormatException('$operation returned an invalid payload');
    }

    try {
      return Uint8List.fromList(data.asTypedList(length));
    } finally {
      LocalFree(HLOCAL(data.cast()));
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as path;

/// An image-only failure leaves authoritative metadata usable and retryable.
class WindowsBackgroundMigrationPending implements Exception {
  const WindowsBackgroundMigrationPending(this.cause);
  final Object cause;
  @override
  String toString() => 'Saved background migration is pending';
}

/// Keeps a committed user store authoritative across permission changes.
class WindowsSettingsMigration {
  static const markerName = '.portable-migration-v1';
  static const _maxBytes = 20 * 1024 * 1024;

  static Future<bool> isCommitted(String directory) async {
    // Never confuse an unreadable authoritative store with a missing marker.
    // Listing also validates uncommitted destination ancestors before copying.
    final files = await readableSourceFiles(directory, {markerName});
    if (!files.contains(markerName)) {
      return false;
    }
    final marker = File(path.join(directory, markerName));
    final type = await FileSystemEntity.type(marker.path, followLinks: false);
    if (type != FileSystemEntityType.file || await marker.length() > 16) {
      throw const FileSystemException('Installed migration marker is invalid');
    }
    if ((await marker.readAsString()).trim() != '1') {
      throw const FormatException('Installed migration marker is invalid');
    }
    return true;
  }

  /// Listing reports permission failures that file-type probes can hide.
  static Future<Set<String>> readableSourceFiles(
      String source, Set<String> names) async {
    await _directory(source, allowMissing: true);
    final found = <String>{};
    final wanted = {
      for (final name in names)
        (Platform.isWindows ? name.toLowerCase() : name): name,
    };
    try {
      await for (final entity in Directory(source).list(followLinks: false)) {
        final basename = path.basename(entity.path);
        final name =
            wanted[Platform.isWindows ? basename.toLowerCase() : basename];
        if (name != null) found.add(name);
      }
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) return found;
      rethrow;
    }
    await _directory(source);
    for (final name in found) {
      if (await FileSystemEntity.type(path.join(source, name),
              followLinks: false) ==
          FileSystemEntityType.notFound) {
        throw FileSystemException(
            'Installed data became inaccessible', path.join(source, name));
      }
    }
    return found;
  }

  static Future<void> repairBackground(
      String source, String destination) async {
    final settingsFile = File(path.join(destination, 'settings.json'));
    if (await FileSystemEntity.type(settingsFile.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    await _regular(settingsFile.path, FileSystemEntityType.file);
    final settingsBytes = await _boundedRead(settingsFile);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(settingsBytes));
    } on FormatException {
      // Normal settings loading owns corrupt-data recovery, not image repair.
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final storedPath = decoded['customBackgroundPath'];
    if (storedPath is! String || storedPath.isEmpty) return;
    final original = path.normalize(path.absolute(storedPath));
    final folder = path.basename(path.dirname(original));
    if (!path.equals(path.dirname(path.dirname(original)),
            path.normalize(path.absolute(path.join(source, 'backgrounds')))) ||
        !folder.startsWith('image-') ||
        path.basename(original) != 'background.png') {
      return;
    }
    await _directory(destination);
    try {
      final targetFolder = path.join(destination, 'backgrounds', folder);
      final target = File(path.join(targetFolder, 'background.png'));
      final receipt = File(path.join(targetFolder, '.migration-receipt.json'));
      final List<int> bytes;
      if (await FileSystemEntity.type(original, followLinks: false) ==
          FileSystemEntityType.notFound) {
        // An interrupted JSON commit can outlive its source. Only a copy
        // bound to this exact reference and a durable digest may be adopted.
        if (await FileSystemEntity.type(receipt.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          return;
        }
        await _directory(targetFolder);
        await _regular(receipt.path, FileSystemEntityType.file);
        if (await receipt.length() > 64 * 1024) {
          throw const FormatException('Background receipt exceeds its limit');
        }
        final record = jsonDecode(utf8.decode(await _boundedRead(receipt)));
        await _regular(target.path, FileSystemEntityType.file);
        bytes = await _boundedRead(target);
        if (record is! Map<String, dynamic> ||
            record['source'] != original ||
            record['sha256'] != sha256.convert(bytes).toString() ||
            bytes.isEmpty) {
          throw const FormatException('Background receipt does not match');
        }
      } else {
        await _directory(source);
        await _directory(path.join(source, 'backgrounds'));
        await _directory(path.dirname(original));
        await _regular(original, FileSystemEntityType.file);
        bytes = await _boundedRead(File(original));
        if (bytes.isEmpty) {
          throw const FormatException('Saved background is empty');
        }
        await _createDirectory(path.join(destination, 'backgrounds'));
        await _createDirectory(targetFolder);
        final targetType =
            await FileSystemEntity.type(target.path, followLinks: false);
        if (targetType != FileSystemEntityType.notFound) {
          await _regular(target.path, FileSystemEntityType.file);
          if (!listEquals(bytes, await _boundedRead(target))) {
            throw StateError('Saved background conflicts with migrated data');
          }
        }
        final receiptType =
            await FileSystemEntity.type(receipt.path, followLinks: false);
        if (receiptType != FileSystemEntityType.notFound) {
          await _regular(receipt.path, FileSystemEntityType.file);
        }
        // Persist recovery evidence before the independent image/JSON commits.
        await _atomicWrite(
            receipt,
            utf8.encode(jsonEncode({
              'source': original,
              'sha256': sha256.convert(bytes).toString(),
            })));
        if (targetType == FileSystemEntityType.notFound) {
          await _atomicWrite(target, bytes);
        }
      }
      // Never publish a setting that points at an incomplete or conflicting copy.
      if (!listEquals(bytes, await _boundedRead(target))) {
        throw StateError('Saved background migration verification failed');
      }
      decoded['customBackgroundPath'] = target.absolute.path;
      await _atomicWrite(settingsFile, utf8.encode(jsonEncode(decoded)));
    } catch (error) {
      if (error is FileSystemException ||
          error is FormatException ||
          error is StateError) {
        throw WindowsBackgroundMigrationPending(error);
      }
      rethrow;
    }
  }

  static Future<void> _regular(String name, FileSystemEntityType type) async {
    if (await FileSystemEntity.type(name, followLinks: false) != type) {
      throw const FileSystemException('Migration data has an unsafe file type');
    }
  }

  static Future<void> _directory(String name,
      {bool allowMissing = false}) async {
    // Windows canonical names may expand an ordinary 8.3 alias. Inspect every
    // component without following links instead; this also rejects junctions.
    var current = path.normalize(path.absolute(name));
    while (true) {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          !(allowMissing && type == FileSystemEntityType.notFound)) {
        throw const FileSystemException(
            'Migration data has an unsafe directory');
      }
      if (!Platform.isWindows) return;
      final parent = path.dirname(current);
      if (path.equals(parent, current)) return;
      current = parent;
    }
  }

  static Future<void> _createDirectory(String name) async {
    final type = await FileSystemEntity.type(name, followLinks: false);
    if (type == FileSystemEntityType.notFound) await Directory(name).create();
    await _directory(name);
  }

  static Future<List<int>> _boundedRead(File file) async {
    if (await file.length() > _maxBytes) {
      throw const FileSystemException('Migration data exceeds its size limit');
    }
    final input = await file.open();
    try {
      final bytes = <int>[];
      while (true) {
        final chunk = await input.read(64 * 1024);
        if (chunk.isEmpty) return bytes;
        if (chunk.length > _maxBytes - bytes.length) {
          throw const FileSystemException(
              'Migration data exceeds its size limit');
        }
        bytes.addAll(chunk);
      }
    } finally {
      await input.close();
    }
  }

  static Future<void> _atomicWrite(File target, List<int> bytes) async {
    final staging = await target.parent.createTemp('.background-migration-');
    final temporary = File(path.join(staging.path, 'content'));
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // Cleanup must not mask a failed copy or a completed settings commit.
      }
    }
  }
}

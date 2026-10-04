import 'dart:io';
import 'package:path/path.dart' as path;

/// Keeps a committed user store authoritative across permission changes.
class WindowsSettingsMigration {
  static const markerName = '.portable-migration-v1';

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
}

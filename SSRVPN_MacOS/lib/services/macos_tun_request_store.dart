import 'dart:io';

/// Owns the unprivileged request-file transaction for a macOS TUN session.
class MacosTunRequestStore {
  const MacosTunRequestStore({
    required this.dataDir,
    required this.appPid,
  });

  static const String requestName = '.tun-session-request';

  final String dataDir;
  final int appPid;

  String get requestPath => '$dataDir${Platform.pathSeparator}$requestName';

  List<String> get recoveryRequestPaths {
    final separator = Platform.pathSeparator;
    const bundleDirectory = 'com.ssrvpn.ssrvpnClient';
    final bundledSuffix = '$separator$bundleDirectory${separator}SSRVPN';
    final legacySuffix = '${separator}SSRVPN';
    if (dataDir.endsWith(bundledSuffix)) {
      final supportDirectory = dataDir.substring(
        0,
        dataDir.length - bundledSuffix.length,
      );
      return [
        '$supportDirectory$legacySuffix$separator$requestName',
        requestPath,
      ];
    }
    if (dataDir.endsWith(legacySuffix)) {
      final supportDirectory = dataDir.substring(
        0,
        dataDir.length - legacySuffix.length,
      );
      return [
        requestPath,
        '$supportDirectory$bundledSuffix$separator$requestName',
      ];
    }
    return [requestPath];
  }

  String value(String phase, String? nonce) {
    if (nonce == null) throw StateError('TUN request generation is missing');
    return 'v2:$phase:$appPid:$nonce';
  }

  Future<void> remove() => removeAt(requestPath);

  Future<void> removeAt(String path) async {
    final request = File(path);
    try {
      if (await request.exists()) await request.delete();
    } catch (_) {}
  }

  Future<void> writeAtomically(String contents, String nonce) async {
    final temporary = File('$requestPath.tmp.$appPid.$nonce');
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('TUN request temporary path already exists');
    }
    try {
      await temporary.writeAsString('$contents\n', flush: true);
      if (!await _linkExclusively(temporary.path, requestPath)) {
        throw StateError('TUN request path is already owned');
      }
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
    }
  }

  Future<bool> transitionToRecovery(String? nonce) async {
    if (nonce == null) return false;
    final active = value('active', nonce);
    final recovery = value('recovery', nonce);
    final quarantine = File('$requestPath.transition.$appPid.$nonce');
    try {
      if (await FileSystemEntity.type(requestPath, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final current = (await File(requestPath).readAsString()).trim();
      if (current == recovery) return true;
      if (current != active) return false;
      if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      await File(requestPath).rename(quarantine.path);
      if ((await quarantine.readAsString()).trim() != active) {
        await _restoreQuarantinedRequest(quarantine);
        return false;
      }
      await writeAtomically(recovery, nonce);
      await quarantine.delete();
      return true;
    } catch (_) {
      await _restoreQuarantinedRequest(quarantine);
      return false;
    }
  }

  Future<void> removeCurrentGeneration(String? nonce) async {
    if (nonce == null) return;
    final quarantine = File('$requestPath.cancel.$appPid.$nonce');
    try {
      if (await FileSystemEntity.type(requestPath, followLinks: false) !=
          FileSystemEntityType.file) {
        return;
      }
      final current = (await File(requestPath).readAsString()).trim();
      if (current == value('active', nonce) ||
          current == value('recovery', nonce)) {
        if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return;
        }
        await File(requestPath).rename(quarantine.path);
        final moved = (await quarantine.readAsString()).trim();
        if (moved == value('active', nonce) ||
            moved == value('recovery', nonce)) {
          await quarantine.delete();
        } else {
          await _restoreQuarantinedRequest(quarantine);
        }
      }
    } catch (_) {}
  }

  Future<bool> currentGenerationExists(String? nonce) async {
    if (nonce == null) return false;
    try {
      if (await FileSystemEntity.type(requestPath, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final current = (await File(requestPath).readAsString()).trim();
      return current == value('active', nonce) ||
          current == value('recovery', nonce);
    } catch (_) {
      return true;
    }
  }

  static Future<String?> readRecoveryRequest(String path) async {
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final file = File(path);
      final length = await file.length();
      if (length < 2 || length > 64) return null;
      final contents = await file.readAsString();
      if (!contents.endsWith('\n') ||
          contents.substring(0, contents.length - 1).contains('\n') ||
          contents.contains('\r')) {
        return null;
      }
      final value = contents.substring(0, contents.length - 1);
      return _isValidRecoveryRequest(value) ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _restoreQuarantinedRequest(File quarantine) async {
    try {
      if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return;
      }
      if (await FileSystemEntity.type(requestPath, followLinks: false) ==
              FileSystemEntityType.notFound &&
          await _linkExclusively(quarantine.path, requestPath)) {
        await quarantine.delete();
      }
    } catch (_) {}
  }

  static Future<bool> _linkExclusively(String source, String target) async {
    try {
      final result = await Process.run('/bin/ln', [source, target])
          .timeout(const Duration(seconds: 2));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static bool _isValidRecoveryRequest(String value) {
    final legacyPid = int.tryParse(value);
    if (legacyPid != null) return legacyPid > 1;
    final match = RegExp(
      r'^v2:(active|recovery):([0-9]+):[0-9a-f]{32}$',
    ).firstMatch(value);
    final requestPid = int.tryParse(match?.group(2) ?? '');
    return requestPid != null && requestPid > 1;
  }
}

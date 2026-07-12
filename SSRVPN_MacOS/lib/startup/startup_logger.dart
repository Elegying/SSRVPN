import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class StartupLogger {
  static const int _maxLogSizeBytes = 1024 * 1024;
  static const int _maxEntryBytes = 64 * 1024;
  static File? _file;
  static bool _verbose = false;

  static String get logPath => _file?.path ?? _defaultLogPath();

  static Future<void> init({
    required bool verbose,
    @visibleForTesting File? fileOverride,
  }) async {
    _verbose = verbose;
    try {
      final file = fileOverride ?? File(_defaultLogPath());
      await file.parent.create(recursive: true);
      try {
        await _rotateIfOversized(file);
      } catch (_) {
        // Rotation is best-effort; a diagnostics failure must not block launch.
      }
      _file = file;
      info('Dart startup logger initialized');
    } catch (error) {
      _file = null;
      warning('Dart startup logger unavailable: $error');
    }
  }

  static void info(String message) {
    _write('INFO', message);
  }

  static void warning(String message) {
    _write('WARN', message);
  }

  static void error(String message, Object error, StackTrace? stack) {
    _write('ERROR', '$message: $error');
    if (stack != null) {
      _write('ERROR', stack.toString());
    }
  }

  static void _write(String level, String message) {
    final safeMessage = _boundedMessage(LogRedactor.sanitize(message));
    final line =
        '[${DateTime.now().toIso8601String()}] [$level] $safeMessage\r\n';
    try {
      final file = _file;
      if (file != null) {
        _rotateBeforeWriteSync(file, utf8.encode(line).length);
        file.writeAsStringSync(line, mode: FileMode.append, flush: true);
      }
    } catch (_) {
      // Startup logging must never become a startup dependency.
    }
    if (_verbose || level != 'INFO') {
      debugPrint('[Startup][$level] $safeMessage');
    }
  }

  static Future<void> _rotateIfOversized(File file) async {
    if (!await file.exists() || await file.length() <= _maxLogSizeBytes) {
      return;
    }
    final oldFile = File('${file.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await file.rename(oldFile.path);
  }

  static void _rotateBeforeWriteSync(File file, int incomingBytes) {
    if (!file.existsSync() ||
        file.lengthSync() + incomingBytes <= _maxLogSizeBytes) {
      return;
    }
    final oldFile = File('${file.path}.old');
    if (oldFile.existsSync()) oldFile.deleteSync();
    file.renameSync(oldFile.path);
  }

  static String _boundedMessage(String message) {
    final encoded = utf8.encode(message);
    if (encoded.length <= _maxEntryBytes) return message;
    const marker = '[log entry truncated]\n';
    final markerBytes = utf8.encode(marker);
    return '$marker${utf8.decode(
      encoded.sublist(encoded.length - (_maxEntryBytes - markerBytes.length)),
      allowMalformed: true,
    )}';
  }

  static String _defaultLogPath() {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      final root = (home == null || home.trim().isEmpty)
          ? Directory.systemTemp.path
          : '$home${Platform.pathSeparator}Library'
              '${Platform.pathSeparator}Application Support';
      return '$root${Platform.pathSeparator}SSRVPN'
          '${Platform.pathSeparator}logs'
          '${Platform.pathSeparator}startup.log';
    }

    final base = Platform.environment['LOCALAPPDATA'];
    final root = (base == null || base.trim().isEmpty)
        ? Directory.systemTemp.path
        : base;
    return '$root${Platform.pathSeparator}SSRVPN'
        '${Platform.pathSeparator}logs'
        '${Platform.pathSeparator}startup.log';
  }
}

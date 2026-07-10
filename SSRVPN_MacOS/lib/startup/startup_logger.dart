import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class StartupLogger {
  static File? _file;
  static bool _verbose = false;

  static String get logPath => _file?.path ?? _defaultLogPath();

  static Future<void> init({required bool verbose}) async {
    _verbose = verbose;
    try {
      final file = File(_defaultLogPath());
      await file.parent.create(recursive: true);
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
    final safeMessage = LogRedactor.sanitize(message);
    final line =
        '[${DateTime.now().toIso8601String()}] [$level] $safeMessage\r\n';
    try {
      _file?.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // Startup logging must never become a startup dependency.
    }
    if (_verbose || level != 'INFO') {
      debugPrint('[Startup][$level] $safeMessage');
    }
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

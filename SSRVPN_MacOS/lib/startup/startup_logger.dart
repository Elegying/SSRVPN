import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class StartupLogger {
  static DesktopStartupFileLogger? _logger;

  static DesktopStartupFileLogger get _current =>
      _logger ??= _createLogger(File(_defaultLogPath()), verbose: false);

  static String get logPath => _current.file.path;

  static Future<void> init({
    required bool verbose,
    @visibleForTesting File? fileOverride,
  }) async {
    final logger = _createLogger(
      fileOverride ?? File(_defaultLogPath()),
      verbose: verbose,
    );
    _logger = logger;
    await logger.initialize();
  }

  static void info(String message) => _current.info(message);

  static void warning(String message) => _current.warning(message);

  static void error(String message, Object error, StackTrace? stack) =>
      _current.error(message, error, stack);

  static DesktopStartupFileLogger _createLogger(
    File file, {
    required bool verbose,
  }) {
    return DesktopStartupFileLogger(
      file,
      verbose: verbose,
      onConsole: debugPrint,
    );
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

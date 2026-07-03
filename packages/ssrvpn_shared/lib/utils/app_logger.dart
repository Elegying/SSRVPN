import 'package:flutter/foundation.dart';

import 'log_redactor.dart';

class AppLogger {
  static bool verbose = !kReleaseMode;

  static void setVerbose(bool value) {
    verbose = value;
  }

  static void info(String tag, Object? message) {
    _write('INFO', tag, message);
  }

  static void warning(String tag, Object? message, [StackTrace? stack]) {
    _write('WARN', tag, message, stack: stack, force: true);
  }

  static void error(
    String tag,
    Object? message, {
    Object? error,
    StackTrace? stack,
  }) {
    final fullMessage = error == null ? message : '$message: $error';
    _write('ERROR', tag, fullMessage, stack: stack, force: true);
  }

  static void _write(
    String level,
    String tag,
    Object? message, {
    StackTrace? stack,
    bool force = false,
  }) {
    if (!force && !verbose) return;
    final safeMessage = LogRedactor.sanitize(message);
    debugPrint('[$tag][$level] $safeMessage');
    if (stack != null) {
      debugPrint('[$tag][$level] ${LogRedactor.sanitize(stack)}');
    }
  }
}

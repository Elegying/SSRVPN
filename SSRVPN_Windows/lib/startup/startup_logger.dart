import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class StartupLogger {
  static const int _maxLogSizeBytes = 1024 * 1024;
  static File? _file;
  static bool _verbose = false;
  static bool _desktopFailureReportWritten = false;

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

  static String? writeDesktopFailureReportSync(
    String reason, {
    Object? error,
    StackTrace? stack,
  }) {
    if (_desktopFailureReportWritten) return null;
    _desktopFailureReportWritten = true;

    try {
      final desktop = _desktopDirectory();
      if (desktop == null) return null;
      desktop.createSync(recursive: true);

      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '')
          .replaceAll('-', '');
      final report = File(
        '${desktop.path}${Platform.pathSeparator}'
        'SSRVPN_Startup_Failure_$stamp.log',
      );

      final buffer = StringBuffer()
        ..writeln('SSRVPN startup failure report')
        ..writeln('Generated: ${DateTime.now().toIso8601String()}')
        ..writeln('Reason: ${LogRedactor.sanitize(reason)}')
        ..writeln('Executable: ${Platform.resolvedExecutable}')
        ..writeln('Arguments: ${Platform.executableArguments.join(' ')}')
        ..writeln('Startup log: $logPath');
      if (error != null) {
        buffer.writeln('Error: ${LogRedactor.sanitize(error.toString())}');
      }
      if (stack != null) {
        buffer
          ..writeln('')
          ..writeln('---- stack trace ----')
          ..writeln(LogRedactor.sanitize(stack.toString()));
      }
      buffer
        ..writeln('')
        ..writeln('---- startup.log ----');

      final startupLog =
          _file?.existsSync() == true ? _file!.readAsStringSync() : null;
      buffer.writeln(
        startupLog == null || startupLog.trim().isEmpty
            ? '<startup.log is empty or missing>'
            : startupLog,
      );

      report.writeAsStringSync(buffer.toString(), flush: true);
      info('Desktop startup failure report written: ${report.path}');
      return report.path;
    } catch (_) {
      return null;
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

  static Future<void> _rotateIfOversized(File file) async {
    if (!await file.exists() || await file.length() <= _maxLogSizeBytes) {
      return;
    }
    final oldFile = File('${file.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await file.rename(oldFile.path);
  }

  static String _defaultLogPath() {
    final base = Platform.environment['LOCALAPPDATA'];
    final root = (base == null || base.trim().isEmpty)
        ? Directory.systemTemp.path
        : base;
    return '$root${Platform.pathSeparator}SSRVPN'
        '${Platform.pathSeparator}logs'
        '${Platform.pathSeparator}startup.log';
  }

  static Directory? _desktopDirectory() {
    final candidates = <String?>[
      Platform.environment['USERPROFILE'] == null
          ? null
          : '${Platform.environment['USERPROFILE']}'
              '${Platform.pathSeparator}Desktop',
      Platform.environment['OneDrive'] == null
          ? null
          : '${Platform.environment['OneDrive']}'
              '${Platform.pathSeparator}Desktop',
      Platform.environment['OneDriveConsumer'] == null
          ? null
          : '${Platform.environment['OneDriveConsumer']}'
              '${Platform.pathSeparator}Desktop',
      Platform.environment['OneDriveCommercial'] == null
          ? null
          : '${Platform.environment['OneDriveCommercial']}'
              '${Platform.pathSeparator}Desktop',
    ];

    for (final candidate in candidates) {
      if (candidate == null || candidate.trim().isEmpty) continue;
      final directory = Directory(candidate);
      if (directory.existsSync()) return directory;
    }

    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null && userProfile.trim().isNotEmpty) {
      return Directory('$userProfile${Platform.pathSeparator}Desktop');
    }
    return null;
  }
}

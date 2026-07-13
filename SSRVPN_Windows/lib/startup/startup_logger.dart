import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class StartupLogger {
  static DesktopStartupFileLogger? _logger;
  static bool _desktopFailureReportWritten = false;

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

      final startupLog = _current.readContentsIfPresentSync();
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

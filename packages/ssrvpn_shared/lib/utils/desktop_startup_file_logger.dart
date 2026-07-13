import 'dart:convert';
import 'dart:io';

import 'log_redactor.dart';

typedef StartupConsoleWriter = void Function(String message);

/// Best-effort synchronous startup logging shared by desktop clients.
///
/// The host application supplies the platform-specific file location and
/// console writer. Failures are intentionally swallowed so diagnostics never
/// become a startup dependency.
class DesktopStartupFileLogger {
  DesktopStartupFileLogger(
    this.file, {
    required this.verbose,
    required this.onConsole,
  });

  static const int _maxLogSizeBytes = 1024 * 1024;
  static const int _maxEntryBytes = 64 * 1024;

  final File file;
  final bool verbose;
  final StartupConsoleWriter onConsole;
  bool _available = false;

  Future<void> initialize() async {
    try {
      await file.parent.create(recursive: true);
      try {
        await _rotateIfOversized();
      } catch (_) {
        // Rotation is best-effort; a diagnostics failure must not block launch.
      }
      _available = true;
      info('Dart startup logger initialized');
    } catch (error) {
      _available = false;
      warning('Dart startup logger unavailable: $error');
    }
  }

  void info(String message) => _write('INFO', message);

  void warning(String message) => _write('WARN', message);

  void error(String message, Object error, StackTrace? stack) {
    _write('ERROR', '$message: $error');
    if (stack != null) {
      _write('ERROR', stack.toString());
    }
  }

  String? readContentsIfPresentSync() {
    if (!_available || !file.existsSync()) return null;
    return file.readAsStringSync();
  }

  void _write(String level, String message) {
    final safeMessage = _boundedMessage(LogRedactor.sanitize(message));
    final line =
        '[${DateTime.now().toIso8601String()}] [$level] $safeMessage\r\n';
    try {
      if (_available) {
        _rotateBeforeWriteSync(utf8.encode(line).length);
        file.writeAsStringSync(line, mode: FileMode.append, flush: true);
      }
    } catch (_) {
      // Startup logging must never become a startup dependency.
    }
    if (verbose || level != 'INFO') {
      onConsole('[Startup][$level] $safeMessage');
    }
  }

  Future<void> _rotateIfOversized() async {
    if (!await file.exists() || await file.length() <= _maxLogSizeBytes) {
      return;
    }
    final oldFile = File('${file.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await file.rename(oldFile.path);
  }

  void _rotateBeforeWriteSync(int incomingBytes) {
    if (!file.existsSync() ||
        file.lengthSync() + incomingBytes <= _maxLogSizeBytes) {
      return;
    }
    final oldFile = File('${file.path}.old');
    if (oldFile.existsSync()) oldFile.deleteSync();
    file.renameSync(oldFile.path);
  }

  String _boundedMessage(String message) {
    final encoded = utf8.encode(message);
    if (encoded.length <= _maxEntryBytes) return message;
    const marker = '[log entry truncated]\n';
    final markerBytes = utf8.encode(marker);
    return '$marker${utf8.decode(
      encoded.sublist(encoded.length - (_maxEntryBytes - markerBytes.length)),
      allowMalformed: true,
    )}';
  }
}

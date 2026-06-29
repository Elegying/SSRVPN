import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';

/// 启动日志记录器
///
/// 轻量级日志，写入应用内部存储，便排查启动问题
class StartupLogger {
  /// 日志文件最大大小（字节），超过后自动轮转删除
  static const int maxLogSizeBytes = 256 * 1024;

  static File? _logFile;
  static bool _verbose = false;
  static final List<String> _buffer = [];
  static const _maxBuffer = 50;

  static Future<void> init({bool verbose = false}) async {
    _verbose = verbose;
    try {
      // Android 内部存储路径
      final dir = Directory('/data/data/com.ssrvpn.app/files/logs');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logFile = File('${dir.path}/startup.log');
      // 轮转：超过 maxLogSizeBytes 删除
      if (await _logFile!.exists()) {
        final length = await _logFile!.length();
        if (length > maxLogSizeBytes) {
          await _logFile!.delete();
        }
      }
    } catch (_) {
      _logFile = null;
    }
  }

  /// 日志敏感数据过滤
  static String _sanitize(String msg) {
    return LogRedactor.sanitize(msg);
  }

  static void info(String message) {
    final safe = _sanitize(message);
    _emit('INFO', safe);
    if (_verbose) debugPrint('[Startup] $safe');
  }

  static void warn(String message) {
    final safe = _sanitize(message);
    _emit('WARN', safe);
    debugPrint('[Startup] ⚠ $safe');
  }

  static void error(String context, Object error, [StackTrace? stack]) {
    final msg = _sanitize('$context: $error');
    _emit('ERROR', msg);
    debugPrint('[Startup] ❌ $msg');
    if (stack != null) {
      final trace = _sanitize(stack.toString());
      _emit('TRACE', trace);
      debugPrint('[Startup]   $trace');
    }
  }

  static void _emit(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final entry = '[$timestamp] [$level] $message';

    _buffer.add(entry);
    if (_buffer.length > _maxBuffer) {
      _buffer.removeAt(0);
    }

    if (_logFile != null) {
      try {
        _logFile!.writeAsStringSync('$entry\n', mode: FileMode.append);
      } catch (_) {}
    }
  }

  /// 获取最近的日志条目
  static List<String> get recentLogs => List.unmodifiable(_buffer);

  /// 日志文件路径
  static String? get logFilePath => _logFile?.path;
}

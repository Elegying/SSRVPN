import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'startup_logger.dart';

class WindowStateStore {
  static const Size defaultSize = Size(1180, 760);
  static const Size minimumSize = Size(820, 560);

  static Future<void> clear() async {
    final file = File(_path());
    try {
      if (await file.exists()) {
        await file.delete();
        StartupLogger.info('Cleared saved window state');
      }
    } catch (error, stack) {
      StartupLogger.error('Failed to clear window state', error, stack);
    }
  }

  static Future<Rect?> load() async {
    final file = File(_path());
    if (!await file.exists()) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('window state must be a JSON object');
      }
      if (decoded['schemaVersion'] != 1) {
        throw const FormatException('unsupported window state schema');
      }
      final left = _readDouble(decoded['left']);
      final top = _readDouble(decoded['top']);
      final width = _readDouble(decoded['width']);
      final height = _readDouble(decoded['height']);
      final rect = Rect.fromLTWH(left, top, width, height);
      if (!_isSane(rect)) {
        throw FormatException('invalid window bounds: $rect');
      }
      return rect;
    } catch (error, stack) {
      StartupLogger.error('Invalid window state; backing it up', error, stack);
      await _backupBadFile(file);
      return null;
    }
  }

  static Future<void> save(Rect bounds) async {
    if (!_isSane(bounds)) return;
    final file = File(_path());
    final payload = jsonEncode({
      'schemaVersion': 1,
      'left': bounds.left,
      'top': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
    });

    try {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(payload, flush: true);
      await temp.rename(file.path);
    } catch (error, stack) {
      StartupLogger.error('Failed to save window state', error, stack);
    }
  }

  static double _readDouble(Object? value) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number == null || !number.isFinite) {
      throw FormatException('invalid numeric value: $value');
    }
    return number;
  }

  static bool _isSane(Rect rect) {
    return rect.left.isFinite &&
        rect.top.isFinite &&
        rect.width.isFinite &&
        rect.height.isFinite &&
        rect.width >= minimumSize.width &&
        rect.height >= minimumSize.height &&
        rect.width <= 10000 &&
        rect.height <= 10000;
  }

  static Future<void> _backupBadFile(File file) async {
    try {
      if (!await file.exists()) return;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      await file.rename('${file.path}.bad-$stamp');
    } catch (error, stack) {
      StartupLogger.error('Failed to back up bad window state', error, stack);
    }
  }

  static String _path() {
    final base = Platform.environment['LOCALAPPDATA'];
    final root = (base == null || base.trim().isEmpty)
        ? Directory.systemTemp.path
        : base;
    return '$root${Platform.pathSeparator}SSRVPN'
        '${Platform.pathSeparator}window_state.json';
  }
}

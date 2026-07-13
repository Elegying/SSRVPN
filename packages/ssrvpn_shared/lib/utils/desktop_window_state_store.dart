import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

typedef WindowStateInfoLogger = void Function(String message);
typedef WindowStateErrorLogger = void Function(
  String message,
  Object error,
  StackTrace? stack,
);

/// Persists desktop window bounds while leaving platform path selection and
/// logging policy to the host application.
class DesktopWindowStateStore {
  DesktopWindowStateStore(
    this.file, {
    this.onInfo,
    this.onError,
  });

  static const Size defaultSize = Size(1180, 760);
  static const Size minimumSize = Size(820, 560);

  final File file;
  final WindowStateInfoLogger? onInfo;
  final WindowStateErrorLogger? onError;

  Future<void> clear() async {
    try {
      if (await file.exists()) {
        await file.delete();
        onInfo?.call('Cleared saved window state');
      }
    } catch (error, stack) {
      onError?.call('Failed to clear window state', error, stack);
    }
  }

  Future<Rect?> load() async {
    if (!await file.exists()) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('window state must be a JSON object');
      }
      if (decoded['schemaVersion'] != 1) {
        throw const FormatException('unsupported window state schema');
      }
      final rect = Rect.fromLTWH(
        _readDouble(decoded['left']),
        _readDouble(decoded['top']),
        _readDouble(decoded['width']),
        _readDouble(decoded['height']),
      );
      if (!_isSane(rect)) {
        throw FormatException('invalid window bounds: $rect');
      }
      return rect;
    } catch (error, stack) {
      onError?.call('Invalid window state; backing it up', error, stack);
      await _backupBadFile();
      return null;
    }
  }

  Future<void> save(Rect bounds) async {
    if (!_isSane(bounds)) return;
    final payload = jsonEncode({
      'schemaVersion': 1,
      'left': bounds.left,
      'top': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
    });

    try {
      await file.parent.create(recursive: true);
      final temporaryFile = File('${file.path}.tmp');
      await temporaryFile.writeAsString(payload, flush: true);
      await temporaryFile.rename(file.path);
    } catch (error, stack) {
      onError?.call('Failed to save window state', error, stack);
    }
  }

  double _readDouble(Object? value) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number == null || !number.isFinite) {
      throw FormatException('invalid numeric value: $value');
    }
    return number;
  }

  bool _isSane(Rect rect) {
    return rect.left.isFinite &&
        rect.top.isFinite &&
        rect.width.isFinite &&
        rect.height.isFinite &&
        rect.width >= minimumSize.width &&
        rect.height >= minimumSize.height &&
        rect.width <= 10000 &&
        rect.height <= 10000;
  }

  Future<void> _backupBadFile() async {
    try {
      if (!await file.exists()) return;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      await file.rename('${file.path}.bad-$stamp');
    } catch (error, stack) {
      onError?.call('Failed to back up bad window state', error, stack);
    }
  }
}

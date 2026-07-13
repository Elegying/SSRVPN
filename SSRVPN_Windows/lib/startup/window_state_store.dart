import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'startup_logger.dart';

class WindowStateStore {
  static const Size defaultSize = DesktopWindowStateStore.defaultSize;
  static const Size minimumSize = DesktopWindowStateStore.minimumSize;

  static Future<void> clear() => _store().clear();

  static Future<Rect?> load() => _store().load();

  static Future<void> save(Rect bounds) => _store().save(bounds);

  static DesktopWindowStateStore _store() => DesktopWindowStateStore(
        File(_path()),
        onInfo: StartupLogger.info,
        onError: StartupLogger.error,
      );

  static String _path() {
    final base = Platform.environment['LOCALAPPDATA'];
    final root = (base == null || base.trim().isEmpty)
        ? Directory.systemTemp.path
        : base;
    return '$root${Platform.pathSeparator}SSRVPN'
        '${Platform.pathSeparator}window_state.json';
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../services/clash_service.dart' as clash;
import '../services/settings_service.dart';
import '../services/subscription_service.dart';
import '../services/tray_manager.dart';
import 'startup_flags.dart';
import 'startup_logger.dart';
import 'startup_status.dart';
import 'window_state_store.dart';

class StartupOrchestrator {
  StartupOrchestrator(this.flags);

  final StartupFlags flags;

  Future<void> start() async {
    final status = StartupStatus.instance;
    status.markStarting();
    StartupLogger.info('Startup flags: $flags');

    await runStep('window_manager', initWindowManager);
    await runStep('screen_retriever', initScreenRetriever);
    await runStep('system_tray', initSystemTray);
    await runStep('mihomo_core', initCoreService);

    status.markCompleted();
    StartupLogger.info('Startup orchestration completed');
  }

  Future<void> runStep(
    String name,
    Future<void> Function() step,
  ) async {
    StartupStatus.instance.markStepStarted(name);
    StartupLogger.info('START $name');
    try {
      await step().timeout(const Duration(seconds: 8));
      StartupLogger.info('OK $name');
      StartupStatus.instance.markStepOk(name);
    } catch (error, stack) {
      StartupLogger.error('FAILED $name', error, stack);
      StartupStatus.instance.reportFailure(name, error);
    }
  }

  Future<void> initWindowManager() async {
    if (flags.safeMode) {
      StartupLogger.info('window_manager skipped by --safe-mode');
      return;
    }

    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(WindowStateStore.minimumSize);

    final savedBounds =
        flags.resetWindow ? null : await WindowStateStore.load();
    final useSavedBounds =
        savedBounds != null && await _intersectsAnyDisplay(savedBounds);

    if (useSavedBounds) {
      await windowManager.setBounds(savedBounds);
      StartupLogger.info('Restored window bounds: $savedBounds');
    } else {
      if (savedBounds != null) {
        StartupLogger.warning(
          'Saved window bounds are outside current displays: $savedBounds',
        );
      }
      await windowManager.setSize(WindowStateStore.defaultSize);
      try {
        await windowManager.center();
      } catch (error, stack) {
        StartupLogger.error('windowManager.center failed', error, stack);
      }
    }

    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> initScreenRetriever() async {
    if (flags.safeMode) {
      StartupLogger.info('screen_retriever skipped by --safe-mode');
      return;
    }

    final displays = await screenRetriever.getAllDisplays();
    StartupLogger.info('Display count: ${displays.length}');
    for (final display in displays) {
      final bounds = _displayBounds(display);
      StartupLogger.info('Display ${display.id}: $bounds');
    }
  }

  Future<void> initSystemTray() async {
    if (flags.disableTray) {
      StartupLogger.info('System tray skipped by startup flags');
      return;
    }

    final tray = TrayManager();
    tray.onShowApp = () async {
      try {
        await windowManager.show();
        await windowManager.restore();
        await windowManager.focus();
      } catch (error, stack) {
        StartupLogger.error('Tray show action failed', error, stack);
      }
    };
    tray.onHideApp = () async {
      try {
        await windowManager.hide();
      } catch (error, stack) {
        StartupLogger.error('Tray hide action failed', error, stack);
      }
    };
    tray.onQuit = () async {
      await _quitFromTray();
    };
    tray.isConnected =
        () => StartupStatus.instance.clashService?.isRunning ?? false;

    final ok = await tray.init();
    if (!ok) {
      throw StateError('system tray plugin returned false');
    }
  }

  Future<void> initCoreService() async {
    final settings = await SettingsService.getInstance();
    final core = clash.ClashService();
    final subscription = await SubscriptionService.getInstance(
      settings.dataDir,
    );

    StartupStatus.instance.setServices(
      settings: settings,
      clash: core,
      subscription: subscription,
    );

    if (flags.disableCoreAutostart) {
      await core.init(
        settings.settings,
        dataDir: settings.dataDir,
        storageNotice: settings.storageNotice,
        skipCoreProbes: true,
      );
      StartupLogger.info('Mihomo core probes skipped by startup flags');
      return;
    }

    Object? coreFailure;
    StackTrace? coreFailureStack;
    try {
      await core.init(
        settings.settings,
        dataDir: settings.dataDir,
        storageNotice: settings.storageNotice,
      );
      if (!core.coreExists) {
        coreFailure = StateError('mihomo.exe not found: ${core.corePath}');
      }
    } catch (error, stack) {
      core.disableStartup('Mihomo 初始化失败: $error');
      coreFailure = error;
      coreFailureStack = stack;
    }

    if (coreFailure != null) {
      Error.throwWithStackTrace(
        coreFailure,
        coreFailureStack ?? StackTrace.current,
      );
    }
  }

  Future<bool> _intersectsAnyDisplay(Rect rect) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return false;
      return displays.any((display) => rect.overlaps(_displayBounds(display)));
    } catch (error, stack) {
      StartupLogger.error('Display lookup failed', error, stack);
      return false;
    }
  }

  Rect _displayBounds(Display display) {
    final size = display.visibleSize ?? display.size;
    final position = display.visiblePosition ?? Offset.zero;
    return Rect.fromLTWH(
      position.dx,
      position.dy,
      size.width,
      size.height,
    );
  }

  Future<void> _quitFromTray() async {
    final status = StartupStatus.instance;
    try {
      await status.settingsService?.flush();
      await status.clashService?.stop();
      await TrayManager().destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (error, stack) {
      StartupLogger.error('Tray quit action failed', error, stack);
    }
  }
}

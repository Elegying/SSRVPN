import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'app.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';
import 'startup/startup_orchestrator.dart';
import 'startup/startup_status.dart';
import 'startup/window_state_store.dart';

String _crashDirectoryPath() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final portableRoot = '$exeDir${Platform.pathSeparator}ssrvpn';
  final portableCrashDir = '$portableRoot${Platform.pathSeparator}crashes';
  try {
    Directory(portableCrashDir).createSync(recursive: true);
    return portableCrashDir;
  } catch (_) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final root = localAppData == null || localAppData.trim().isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return '$root${Platform.pathSeparator}SSRVPN'
        '${Platform.pathSeparator}ssrvpn'
        '${Platform.pathSeparator}crashes';
  }
}

void _writeStartupFailureReport(
  String reason, {
  Object? error,
  StackTrace? stack,
}) {
  CrashReporter.recordSync(reason, error ?? reason, stack);
  if (StartupStatus.instance.completed) return;
  StartupLogger.writeDesktopFailureReportSync(
    reason,
    error: error,
    stack: stack,
  );
}

void main(List<String> args) {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    final flags = StartupFlags.parse(args);
    await StartupLogger.init(verbose: flags.verbose);
    CrashReporter.initSync(_crashDirectoryPath());
    StartupLogger.info('main() entered with args: ${args.join(' ')}');

    FlutterError.onError = (details) {
      StartupLogger.error(
        'FlutterError',
        details.exception,
        details.stack,
      );
      _writeStartupFailureReport(
        'FlutterError during startup',
        error: details.exception,
        stack: details.stack,
      );
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      StartupLogger.error('PlatformDispatcher error', error, stack);
      _writeStartupFailureReport(
        'PlatformDispatcher error during startup',
        error: error,
        stack: stack,
      );
      return true;
    };

    if (flags.resetWindow) {
      await WindowStateStore.clear();
    }

    runApp(SSRVpnApp(startupFlags: flags));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(StartupOrchestrator(flags).start());
    });
  }, (error, stack) {
    StartupLogger.error('Uncaught startup zone error', error, stack);
    _writeStartupFailureReport(
      'Uncaught startup zone error',
      error: error,
      stack: stack,
    );
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'app.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';
import 'startup/startup_orchestrator.dart';
import 'startup/window_state_store.dart';

String _crashDirectoryPath() {
  final appRoot = File(StartupLogger.logPath).parent.parent;
  return '${appRoot.path}${Platform.pathSeparator}crashes';
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
      CrashReporter.recordSync(
        'FlutterError',
        details.exception,
        details.stack,
      );
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      StartupLogger.error('PlatformDispatcher error', error, stack);
      CrashReporter.recordSync('PlatformDispatcher error', error, stack);
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
    CrashReporter.recordSync('Uncaught startup zone error', error, stack);
  });
}

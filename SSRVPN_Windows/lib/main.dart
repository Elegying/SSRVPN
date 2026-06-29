import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';
import 'startup/startup_orchestrator.dart';
import 'startup/window_state_store.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final flags = StartupFlags.parse(args);
  await StartupLogger.init(verbose: flags.verbose);
  StartupLogger.info('main() entered with args: ${args.join(' ')}');

  FlutterError.onError = (details) {
    StartupLogger.error(
      'FlutterError',
      details.exception,
      details.stack,
    );
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    StartupLogger.error('PlatformDispatcher error', error, stack);
    return true;
  };

  if (flags.resetWindow) {
    await WindowStateStore.clear();
  }

  runApp(SSRVpnApp(startupFlags: flags));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(StartupOrchestrator(flags).start());
  });
}

import 'dart:io';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'startup_logger.dart';

Future<bool> initializeCrashReporterBestEffort({
  required Future<Directory> Function() resolveSupportDirectory,
  Future<void> Function(String path) initializeCrashReporter =
      CrashReporter.init,
}) async {
  try {
    final supportDir = await resolveSupportDirectory();
    await initializeCrashReporter(
      '${supportDir.path}${Platform.pathSeparator}crashes',
    );
    return true;
  } catch (error, stack) {
    StartupLogger.error('Crash reporter initialization failed', error, stack);
    return false;
  }
}

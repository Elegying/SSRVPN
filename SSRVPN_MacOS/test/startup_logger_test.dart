import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/startup/startup_logger.dart';

void main() {
  test('init stays best-effort when the log directory cannot be created',
      () async {
    final tempDirectory =
        await Directory.systemTemp.createTemp('ssrvpn_startup_logger_test_');
    addTearDown(() => tempDirectory.delete(recursive: true));

    final blocker = File('${tempDirectory.path}/not-a-directory');
    await blocker.writeAsString('occupied');
    final blockedDirectory = Directory(blocker.path);

    final initialization = IOOverrides.runZoned(
      () => StartupLogger.init(verbose: false),
      createDirectory: (_) => blockedDirectory,
    );

    await expectLater(initialization, completes);
  });

  test('file open failures and later writes stay best-effort', () async {
    final tempDirectory =
        await Directory.systemTemp.createTemp('ssrvpn_startup_logger_test_');
    addTearDown(() => tempDirectory.delete(recursive: true));
    final blockedLogFile = File(tempDirectory.path);
    final consoleMessages = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) consoleMessages.add(message);
    };
    addTearDown(() => debugPrint = previousDebugPrint);

    final initialization = IOOverrides.runZoned(
      () => StartupLogger.init(verbose: false),
      createFile: (_) => blockedLogFile,
    );

    await expectLater(initialization, completes);
    StartupLogger.warning('console fallback remains available');
    expect(consoleMessages,
        ['[Startup][WARN] console fallback remains available']);
  });
}

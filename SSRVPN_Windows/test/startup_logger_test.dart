import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/startup/startup_logger.dart';

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

  test('rotates an oversized startup log before appending', () async {
    final tempDirectory =
        await Directory.systemTemp.createTemp('ssrvpn_startup_logger_test_');
    addTearDown(() => tempDirectory.delete(recursive: true));
    final logFile = File('${tempDirectory.path}/startup.log');
    await logFile.writeAsBytes(List.filled(1024 * 1024 + 1, 0x78));

    await StartupLogger.init(
      verbose: false,
      fileOverride: logFile,
    );

    final oldFile = File('${logFile.path}.old');
    expect(await oldFile.exists(), isTrue);
    expect(await oldFile.length(), 1024 * 1024 + 1);
    expect(await logFile.length(), lessThan(1024));
  });

  test('rotates again when the log grows during the same run', () async {
    final tempDirectory =
        await Directory.systemTemp.createTemp('ssrvpn_startup_logger_test_');
    addTearDown(() => tempDirectory.delete(recursive: true));
    final logFile = File('${tempDirectory.path}/startup.log');
    await StartupLogger.init(verbose: false, fileOverride: logFile);
    await logFile.writeAsBytes(List.filled(1024 * 1024 - 32, 0x78));

    StartupLogger.info('runtime rotation');

    expect(await File('${logFile.path}.old').exists(), isTrue);
    expect(await logFile.length(), lessThan(1024));
  });
}

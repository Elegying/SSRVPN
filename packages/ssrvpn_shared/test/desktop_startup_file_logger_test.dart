import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  late Directory tempDirectory;
  late File logFile;
  late List<String> consoleMessages;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('desktop_startup_log_test_');
    logFile = File('${tempDirectory.path}/startup.log');
    consoleMessages = <String>[];
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('rotates an oversized file before the first entry', () async {
    await logFile.writeAsBytes(List.filled(1024 * 1024 + 1, 0x78));
    final logger = DesktopStartupFileLogger(
      logFile,
      verbose: false,
      onConsole: consoleMessages.add,
    );

    await logger.initialize();

    expect(await File('${logFile.path}.old').length(), 1024 * 1024 + 1);
    expect(await logFile.readAsString(), contains('logger initialized'));
    expect(consoleMessages, isEmpty);
  });

  test('rotates again before a runtime write exceeds the limit', () async {
    final logger = DesktopStartupFileLogger(
      logFile,
      verbose: false,
      onConsole: consoleMessages.add,
    );
    await logger.initialize();
    await logFile.writeAsBytes(List.filled(1024 * 1024 - 32, 0x78));

    logger.info('runtime rotation');

    expect(await File('${logFile.path}.old').exists(), isTrue);
    expect(await logFile.length(), lessThan(1024));
  });

  test('keeps warnings on the console and redacts secrets', () async {
    final logger = DesktopStartupFileLogger(
      logFile,
      verbose: false,
      onConsole: consoleMessages.add,
    );
    await logger.initialize();

    logger.warning('token=super-secret');

    expect(consoleMessages, ['[Startup][WARN] token: ***']);
    expect(await logFile.readAsString(), isNot(contains('super-secret')));
  });
}

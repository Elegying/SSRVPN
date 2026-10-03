import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/startup/startup_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup logging bounds a long session and redacts persisted entries',
      () async {
    final directory = await Directory.systemTemp.createTemp('startup-log-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    addTearDown(() async {
      await StartupLogger.flush();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });
    await StartupLogger.init();
    expect(StartupLogger.logFilePath, isNotNull);
    for (var batch = 0; batch < 12; batch++) {
      for (var i = 0; i < 20; i++) {
        StartupLogger.info('${'log ' * 400} password=never-persist-this');
      }
      await StartupLogger.flush();
    }
    final file = File(StartupLogger.logFilePath!);
    expect(
        await file.length(), lessThanOrEqualTo(StartupLogger.maxLogSizeBytes));
    expect(await file.readAsString(), isNot(contains('never-persist-this')));
    expect(StartupLogger.recentLogs, hasLength(50));
  });
}

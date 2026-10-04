import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/app.dart';
import 'package:ssrvpn_windows/startup/startup_flags.dart';
import 'package:ssrvpn_windows/startup/startup_logger.dart';
import 'package:ssrvpn_windows/startup/startup_orchestrator.dart';
import 'package:ssrvpn_windows/startup/startup_status.dart';

void main() {
  testWidgets('close remains handled after partial window initialization fails',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('window-close-');
    await tester.runAsync(() => StartupLogger.init(
        verbose: false, fileOverride: File('${directory.path}/startup.log')));
    final calls = <MethodCall>[];
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setResizable') {
        throw PlatformException(code: 'window_configuration_failed');
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      directory.deleteSync(recursive: true);
    });
    final flags = StartupFlags.parse(const ['--reset-window']);
    await tester.pumpWidget(SSRVpnApp(startupFlags: flags));
    final orchestrator = StartupOrchestrator(flags);
    await tester.runAsync(() =>
        orchestrator.runStep('window_manager', orchestrator.initWindowManager));
    expect(StartupStatus.instance.windowManagerReady, isFalse);
    expect(
        calls.any((c) =>
            c.method == 'setPreventClose' &&
            (c.arguments as Map)['isPreventClose'] == true),
        isTrue);
    // The plugin consumes WM_CLOSE after preventClose is set, even when later
    // native window setup fails. Deliver its real platform event to the app.
    await messenger.handlePlatformMessage(
      'window_manager',
      const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onEvent', {'eventName': 'close'})),
      (_) {},
    );
    await tester.pump();
    expect(calls.map((c) => c.method), contains('destroy'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

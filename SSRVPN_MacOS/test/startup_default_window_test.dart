import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/startup/startup_flags.dart';
import 'package:ssrvpn_macos/startup/startup_logger.dart';
import 'package:ssrvpn_macos/startup/startup_orchestrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final displayAvailable in [true, false]) {
    test(
        'default window startup fits usable display, available=$displayAvailable',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('ssrvpn-default-window-');
      await StartupLogger.init(
          verbose: false, fileOverride: File('${directory.path}/startup.log'));
      final calls = <MethodCall>[];
      const window = MethodChannel('window_manager');
      const screen = MethodChannel('dev.leanflutter.plugins/screen_retriever');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(window, (call) async {
        calls.add(call);
        if (call.method == 'isMinimized') return false;
        if (call.method == 'getBounds') {
          return {'x': 0.0, 'y': 0.0, 'width': 440.0, 'height': 720.0};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(screen, (call) async {
        if (!displayAvailable) {
          throw PlatformException(code: 'display_unavailable');
        }
        return {
          'id': 'test-display',
          'size': {'width': 1280.0, 'height': 720.0},
          'visiblePosition': {'dx': -1280.0, 'dy': 24.0},
          'visibleSize': {'width': 1280.0, 'height': 680.0},
          'scaleFactor': 2
        };
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(window, null);
        messenger.setMockMethodCallHandler(screen, null);
        await directory.delete(recursive: true);
      });
      await StartupOrchestrator(StartupFlags.parse(['--reset-window']))
          .initWindowManager();
      final bounds =
          calls.firstWhere((c) => c.method == 'setBounds').arguments as Map;
      if (displayAvailable) {
        expect(bounds['width'], closeTo(396, .01));
        expect(bounds['height'], closeTo(648, .01));
        expect(bounds['x'], closeTo(-838, .01));
        expect(bounds['y'], closeTo(40, .01));
      } else {
        expect(bounds['width'], 440);
        expect(bounds['height'], 720);
      }
      expect(calls.map((c) => c.method),
          containsAllInOrder(['setMinimumSize', 'setBounds', 'show', 'focus']));
    });
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/app_shutdown.dart';

void main() {
  test('keeps every visible surface alive when core or proxy cleanup fails',
      () async {
    final events = <String>[];

    final failures = await runMacosAppShutdown(
      flushSettings: () async => events.add('flush'),
      stopCore: () async {
        events.add('stop');
        throw StateError('system proxy restore failed');
      },
      allowWindowClose: () async => events.add('allow-close'),
      destroyWindow: () async => events.add('window'),
      destroyTray: () async => events.add('tray'),
    );

    expect(failures, hasLength(1));
    expect(failures.single.step, macosShutdownStopCoreStep);
    expect(events, ['flush', 'stop']);
    expect(isMacosAppShutdownSafeToExit(failures), isFalse);
  });

  test('destroys UI only after settings and core cleanup succeed', () async {
    final events = <String>[];

    final failures = await runMacosAppShutdown(
      flushSettings: () async => events.add('flush'),
      stopCore: () async => events.add('stop'),
      allowWindowClose: () async => events.add('allow-close'),
      destroyWindow: () async => events.add('window'),
      destroyTray: () async => events.add('tray'),
    );

    expect(failures, isEmpty);
    expect(events, ['flush', 'stop', 'allow-close', 'window', 'tray']);
    expect(isMacosAppShutdownSafeToExit(failures), isTrue);
  });

  test('a settings flush failure does not strand a safely stopped app',
      () async {
    final events = <String>[];

    final failures = await runMacosAppShutdown(
      flushSettings: () async => throw StateError('flush failed'),
      stopCore: () async => events.add('stop'),
      allowWindowClose: () async => events.add('allow-close'),
      destroyWindow: () async => events.add('window'),
      destroyTray: () async => events.add('tray'),
    );

    expect(failures, hasLength(1));
    expect(failures.single.step, macosShutdownFlushSettingsStep);
    expect(events, ['stop', 'allow-close', 'window', 'tray']);
    expect(isMacosAppShutdownSafeToExit(failures), isTrue);
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/app_shutdown.dart';

void main() {
  test('hides the window before waiting for slow core cleanup', () async {
    final events = <String>[];
    final stopCompleter = Completer<void>();

    final shutdown = runWindowsAppShutdown(
      hideWindow: () async => events.add('hide'),
      flushSettings: () async => events.add('flush'),
      stopCore: () async {
        events.add('stop-start');
        await stopCompleter.future;
        events.add('stop-end');
      },
      destroyTray: () async => events.add('tray'),
      allowWindowClose: () async => events.add('allow-close'),
      destroyWindow: () async => events.add('destroy'),
    );

    await Future<void>.delayed(Duration.zero);
    expect(events, ['hide', 'flush', 'stop-start']);

    stopCompleter.complete();
    expect(await shutdown, isEmpty);
    expect(events, [
      'hide',
      'flush',
      'stop-start',
      'stop-end',
      'tray',
      'allow-close',
      'destroy',
    ]);
  });

  test('continues shutdown when hiding the window fails', () async {
    final events = <String>[];

    final failures = await runWindowsAppShutdown(
      hideWindow: () async => throw StateError('hide failed'),
      flushSettings: () async => events.add('flush'),
      stopCore: () async => events.add('stop'),
      destroyTray: () async => events.add('tray'),
      allowWindowClose: () async => events.add('allow-close'),
      destroyWindow: () async => events.add('destroy'),
    );

    expect(failures, hasLength(1));
    expect(failures.single.step, 0);
    expect(events, ['flush', 'stop', 'tray', 'allow-close', 'destroy']);
  });

  test('keeps the app alive when core or proxy cleanup fails', () async {
    final events = <String>[];

    final failures = await runWindowsAppShutdown(
      hideWindow: () async => events.add('hide'),
      flushSettings: () async => events.add('flush'),
      stopCore: () async {
        events.add('stop');
        throw StateError('proxy restore failed');
      },
      destroyTray: () async => events.add('tray'),
      allowWindowClose: () async => events.add('allow-close'),
      destroyWindow: () async => events.add('destroy'),
    );

    expect(failures, hasLength(1));
    expect(failures.single.step, 2);
    expect(events, ['hide', 'flush', 'stop']);
  });
}

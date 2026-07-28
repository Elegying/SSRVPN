import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
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
    expect(isWindowsAppShutdownSafeToExit(failures), isTrue);
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
    expect(isWindowsAppShutdownSafeToExit(failures), isFalse);
  });

  test('does not confirm an update exit when window destruction fails',
      () async {
    final failures = await runWindowsAppShutdown(
      hideWindow: () async {},
      flushSettings: () async {},
      stopCore: () async {},
      destroyTray: () async {},
      allowWindowClose: () async {},
      destroyWindow: () async => throw StateError('window remains alive'),
    );

    expect(failures, hasLength(1));
    expect(failures.single.step, 5);
    expect(isWindowsAppShutdownSafeToExit(failures), isFalse);
  });

  test(
    'restores a visible protected window and tray when shutdown is blocked',
    () async {
      var windowVisible = true;
      var preventClose = true;
      var trayReady = true;

      final failures = await runWindowsAppShutdown(
        hideWindow: () async => windowVisible = false,
        flushSettings: () async {},
        stopCore: () async {},
        destroyTray: () async => trayReady = false,
        allowWindowClose: () async => preventClose = false,
        destroyWindow: () async => throw StateError('window remains alive'),
      );

      final recoveryFailures = await recoverWindowsAppAfterBlockedShutdown(
        shutdownFailures: failures,
        restoreCloseProtection: () async => preventClose = true,
        showWindow: () async => windowVisible = true,
        restoreWindow: () async {},
        focusWindow: () async {},
        isTrayReady: () => trayReady,
        initializeTray: () async {
          trayReady = true;
          return true;
        },
      );

      expect(recoveryFailures, isEmpty);
      expect(preventClose, isTrue);
      expect(windowVisible, isTrue);
      expect(trayReady, isTrue);
    },
  );

  test('does not rebuild a tray that survived a blocked core shutdown',
      () async {
    var windowVisible = true;
    var trayInitializations = 0;

    final failures = await runWindowsAppShutdown(
      hideWindow: () async => windowVisible = false,
      flushSettings: () async {},
      stopCore: () async => throw StateError('proxy restore failed'),
      destroyTray: () async {},
      allowWindowClose: () async {},
      destroyWindow: () async {},
    );

    final recoveryFailures = await recoverWindowsAppAfterBlockedShutdown(
      shutdownFailures: failures,
      restoreCloseProtection: () async {},
      showWindow: () async => windowVisible = true,
      restoreWindow: () async {},
      focusWindow: () async {},
      isTrayReady: () => true,
      initializeTray: () async {
        trayInitializations += 1;
        return true;
      },
    );

    expect(recoveryFailures, isEmpty);
    expect(windowVisible, isTrue);
    expect(trayInitializations, 0);
  });

  test('keeps window recovery observable when tray reconstruction fails',
      () async {
    var windowVisible = false;

    final recoveryFailures = await recoverWindowsAppAfterBlockedShutdown(
      shutdownFailures: [
        CleanupFailure(
          step: 5,
          error: StateError('window remains alive'),
          stackTrace: StackTrace.current,
        ),
      ],
      restoreCloseProtection: () async {},
      showWindow: () async => windowVisible = true,
      restoreWindow: () async {},
      focusWindow: () async {},
      isTrayReady: () => false,
      initializeTray: () async => false,
    );

    expect(windowVisible, isTrue);
    expect(recoveryFailures, hasLength(1));
    expect(recoveryFailures.single.step, 10);
  });
}

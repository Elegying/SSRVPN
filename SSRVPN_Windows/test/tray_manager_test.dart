import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/tray_manager.dart';

void main() {
  test('concurrent initialization shares one verified native transaction',
      () async {
    final nativeInitialization = Completer<bool>();
    var nativeInitializationCount = 0;
    var nativeVerificationCount = 0;
    var menuBuildCount = 0;
    var eventRegistrationCount = 0;
    final manager = TrayManager.forTesting(
      initializeNativeTray: (iconAssetPath) async {
        expect(iconAssetPath, 'assets/icon.ico');
        nativeInitializationCount++;
        return nativeInitialization.future;
      },
      verifyNativeTray: (iconAssetPath) async {
        expect(iconAssetPath, 'assets/icon.ico');
        nativeVerificationCount++;
        return true;
      },
      buildMenu: () async => menuBuildCount++,
      registerEventHandler: () => eventRegistrationCount++,
    );

    final first = manager.init();
    final second = manager.init();

    expect(identical(first, second), isTrue);
    expect(nativeInitializationCount, 1);
    expect(nativeVerificationCount, 0);
    expect(manager.isReady, isFalse);

    nativeInitialization.complete(true);

    expect(await Future.wait([first, second]), [true, true]);
    expect(nativeInitializationCount, 1);
    expect(nativeVerificationCount, 1);
    expect(menuBuildCount, 1);
    expect(eventRegistrationCount, 1);
    expect(manager.isReady, isTrue);
    expect(manager.lastError, isNull);
  });

  test('native tray verification failure never publishes ready state',
      () async {
    var menuBuildCount = 0;
    var eventRegistrationCount = 0;
    final manager = TrayManager.forTesting(
      initializeNativeTray: (_) async => true,
      verifyNativeTray: (_) async => false,
      buildMenu: () async => menuBuildCount++,
      registerEventHandler: () => eventRegistrationCount++,
    );

    expect(await manager.init(), isFalse);

    expect(manager.isReady, isFalse);
    expect(manager.lastError, contains('复核'));
    expect(menuBuildCount, 0);
    expect(eventRegistrationCount, 0);
  });

  test('a failed verification remains observable and a later retry can recover',
      () async {
    var nativeInitializationCount = 0;
    var nativeVerificationCount = 0;
    final manager = TrayManager.forTesting(
      initializeNativeTray: (_) async {
        nativeInitializationCount++;
        return true;
      },
      verifyNativeTray: (_) async {
        nativeVerificationCount++;
        if (nativeVerificationCount == 1) {
          throw StateError('synthetic tray verification failure');
        }
        return true;
      },
    );

    expect(await manager.init(), isFalse);
    expect(manager.isReady, isFalse);
    expect(manager.lastError, contains('synthetic tray verification failure'));

    expect(await manager.init(), isTrue);
    expect(nativeInitializationCount, 2);
    expect(nativeVerificationCount, 2);
    expect(manager.isReady, isTrue);
    expect(manager.lastError, isNull);
  });
}

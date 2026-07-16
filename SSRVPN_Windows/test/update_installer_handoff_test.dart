import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/update_service.dart';

void main() {
  tearDown(() {
    UpdateService.onInstallerHandoff = null;
  });

  test('verified installer handoff precedes safe app shutdown', () async {
    final events = <String>[];

    await UpdateService.installVerifiedUpdate(
      File('SSRVPN_Setup.exe'),
      launchInstaller: (_) async => events.add('installer-ready'),
      shutdownApp: () async {
        events.add('proxy-core-clean');
        return true;
      },
    );

    expect(events, ['installer-ready', 'proxy-core-clean']);
  });

  test('handoff failure keeps the running app untouched', () async {
    var shutdownCalled = false;

    await expectLater(
      UpdateService.installVerifiedUpdate(
        File('SSRVPN_Setup.exe'),
        launchInstaller: (_) async => throw StateError('handoff failed'),
        shutdownApp: () async {
          shutdownCalled = true;
          return true;
        },
      ),
      throwsStateError,
    );
    expect(shutdownCalled, isFalse);
  });

  test('proxy cleanup failure aborts update while the app remains alive',
      () async {
    final events = <String>[];

    await expectLater(
      UpdateService.installVerifiedUpdate(
        File('SSRVPN_Setup.exe'),
        launchInstaller: (_) async => events.add('installer-ready'),
        shutdownApp: () async {
          events.add('proxy-cleanup-failed');
          return false;
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('SSRVPN 保持运行'),
        ),
      ),
    );
    expect(events, ['installer-ready', 'proxy-cleanup-failed']);
  });

  test('missing shutdown lifecycle prevents installer launch', () async {
    var launched = false;

    await expectLater(
      UpdateService.installVerifiedUpdate(
        File('SSRVPN_Setup.exe'),
        launchInstaller: (_) async {
          launched = true;
        },
      ),
      throwsStateError,
    );
    expect(launched, isFalse);
  });
}

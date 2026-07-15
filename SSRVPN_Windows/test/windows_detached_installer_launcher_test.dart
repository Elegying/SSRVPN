import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_detached_installer_launcher.dart';

void main() {
  test('launch uses the independent Explorer shell owner', () {
    final command = WindowsDetachedInstallerLauncher.buildLaunchCommand(
      r'C:\Users\Test User\Downloads\SSRVPN_Setup.exe',
    );

    expect(command.executable, 'explorer.exe');
    expect(command.arguments, [
      r'C:\Users\Test User\Downloads\SSRVPN_Setup.exe',
    ]);
  });

  test(
    'launch surfaces an Explorer handoff failure without a fallback',
    () async {
      final started = <WindowsProcessCommand>[];
      final installer = File(r'C:\Temp\SSRVPN_Setup.exe');
      late StackTrace originalStack;
      Object? failure;
      StackTrace? failureStack;

      try {
        await WindowsDetachedInstallerLauncher.launch(
          installer,
          hasShellWindow: () => true,
          start: (command) async {
            started.add(command);
            try {
              throw const FileSystemException('explorer unavailable');
            } catch (_, stackTrace) {
              originalStack = stackTrace;
              rethrow;
            }
          },
        );
      } catch (error, stackTrace) {
        failure = error;
        failureStack = stackTrace;
      }

      expect(started, hasLength(1));
      expect(started.single.executable, 'explorer.exe');
      expect(
        failure,
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains(installer.absolute.path),
            contains('explorer unavailable'),
            contains('请退出 SSRVPN，并手动运行该安装包'),
          ),
        ),
      );
      expect(failureStack.toString(), originalStack.toString());
    },
  );

  test('launch refuses to create a shell inside the app job', () async {
    var started = false;
    final installer = File(r'C:\Temp\SSRVPN_Setup.exe');

    await expectLater(
      WindowsDetachedInstallerLauncher.launch(
        installer,
        hasShellWindow: () => false,
        start: (_) async {
          started = true;
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains(installer.absolute.path),
            contains('Windows 桌面 Shell 当前不可用'),
            contains('请退出 SSRVPN，并手动运行该安装包'),
          ),
        ),
      ),
    );
    expect(started, isFalse);
  });
}

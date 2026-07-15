import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_detached_installer_launcher.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn-update-handoff-test-',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

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
      final installer = File('${tempDirectory.path}/SSRVPN_Setup.exe');
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
    final installer = File('${tempDirectory.path}/SSRVPN_Setup.exe');

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

  test('launch waits for the exact installer handoff acknowledgement',
      () async {
    const token = 'test';
    final installer = File('${tempDirectory.path}/SSRVPN_Setup.exe');
    final request = File(
      '${installer.absolute.path}'
      '${WindowsDetachedInstallerLauncher.handoffRequestSuffix}',
    );
    final status = File(
      '${installer.absolute.path}'
      '${WindowsDetachedInstallerLauncher.handoffStatusSuffix}',
    );

    await WindowsDetachedInstallerLauncher.launch(
      installer,
      hasShellWindow: () => true,
      createToken: () => token,
      start: (command) async {
        expect(command.executable, 'explorer.exe');
        expect(await request.readAsString(), token);
        await status.writeAsString('ready:$token', flush: true);
      },
      handoffTimeout: const Duration(seconds: 1),
      handoffPollInterval: const Duration(milliseconds: 5),
    );

    expect(await request.exists(), isFalse);
    expect(await status.exists(), isFalse);
  });

  test('forged acknowledgement cannot complete the handoff', () async {
    const token = 'test';
    final installer = File('${tempDirectory.path}/SSRVPN_Setup.exe');
    final status = File(
      '${installer.absolute.path}'
      '${WindowsDetachedInstallerLauncher.handoffStatusSuffix}',
    );

    await expectLater(
      WindowsDetachedInstallerLauncher.launch(
        installer,
        hasShellWindow: () => true,
        createToken: () => token,
        start: (_) async {
          await status.writeAsString(
            'ready:forged',
            flush: true,
          );
        },
        handoffTimeout: const Duration(milliseconds: 40),
        handoffPollInterval: const Duration(milliseconds: 5),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('等待更新安装器接管超时'),
        ),
      ),
    );
  });

  test('a stale status file cannot complete a new handoff', () async {
    const token = 'test';
    final installer = File('${tempDirectory.path}/SSRVPN_Setup.exe');
    final status = File(
      '${installer.absolute.path}'
      '${WindowsDetachedInstallerLauncher.handoffStatusSuffix}',
    );
    await status.writeAsString('ready:$token', flush: true);

    await expectLater(
      WindowsDetachedInstallerLauncher.launch(
        installer,
        hasShellWindow: () => true,
        createToken: () => token,
        start: (_) async {},
        handoffTimeout: const Duration(milliseconds: 40),
        handoffPollInterval: const Duration(milliseconds: 5),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('等待更新安装器接管超时'),
        ),
      ),
    );
  });

  test('installer cancellation aborts the handoff', () async {
    const token = 'test';
    final installer = File('${tempDirectory.path}/SSRVPN_Setup.exe');
    final status = File(
      '${installer.absolute.path}'
      '${WindowsDetachedInstallerLauncher.handoffStatusSuffix}',
    );

    await expectLater(
      WindowsDetachedInstallerLauncher.launch(
        installer,
        hasShellWindow: () => true,
        createToken: () => token,
        start: (_) async {
          await status.writeAsString('cancelled:$token', flush: true);
        },
        handoffTimeout: const Duration(seconds: 1),
        handoffPollInterval: const Duration(milliseconds: 5),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('更新安装已取消，SSRVPN 保持运行'),
        ),
      ),
    );
  });
}

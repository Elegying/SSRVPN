import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_detached_installer_launcher.dart';

void main() {
  test('launch plan starts installers through an independent shell owner', () {
    final commands = WindowsDetachedInstallerLauncher.buildLaunchPlan(
      r'C:\Users\Test User\Downloads\SSRVPN_Setup.exe',
    );

    expect(commands, hasLength(2));
    expect(commands.first.executable, 'explorer.exe');
    expect(commands.first.arguments, [
      r'C:\Users\Test User\Downloads\SSRVPN_Setup.exe',
    ]);
    expect(commands.last.executable, 'powershell.exe');
    expect(
      commands.last.arguments,
      contains('Start-Process -LiteralPath \$args[0]'),
    );
    expect(
      commands.last.arguments.last,
      r'C:\Users\Test User\Downloads\SSRVPN_Setup.exe',
    );
  });

  test('launch falls back when the first shell handoff fails', () async {
    final started = <WindowsProcessCommand>[];

    await WindowsDetachedInstallerLauncher.launch(
      File(r'C:\Temp\SSRVPN_Setup.exe'),
      start: (command) async {
        started.add(command);
        if (started.length == 1) {
          throw const FileSystemException('explorer unavailable');
        }
      },
    );

    expect(started.map((command) => command.executable), [
      'explorer.exe',
      'powershell.exe',
    ]);
  });
}

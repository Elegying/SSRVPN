import 'dart:io';

import 'package:ssrvpn_shared/services/update_service.dart';

/// Shared tests do not load the Windows runner's method channel. Supply a real
/// no-replace move on Windows; other hosts keep exercising the POSIX publisher.
VerifiedUpdateFilePublisher? get testVerifiedUpdatePublisher =>
    Platform.isWindows ? _publishWindowsFile : null;

Future<void> _publishWindowsFile(File source, File destination) async {
  final result = await Process.run(
    'powershell.exe',
    [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"$ErrorActionPreference = 'Stop'; "
          r'[System.IO.File]::Move($env:SSRVPN_TEST_SOURCE, '
          r'$env:SSRVPN_TEST_DESTINATION)',
    ],
    environment: {
      'SSRVPN_TEST_SOURCE': source.absolute.path,
      'SSRVPN_TEST_DESTINATION': destination.absolute.path,
    },
  );
  if (result.exitCode != 0) {
    throw FileSystemException(
        'Test no-replace publication failed', destination.path);
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_desktop_directory.dart';

void main() {
  test('uses the Windows known-folder path without rewriting it', () {
    const redirectedDesktop = r'D:\OneDrive - Example\用户文件\桌面';

    final directory = WindowsDesktopDirectory.resolve(
      knownFolderLookup: () => redirectedDesktop,
    );

    expect(directory.path, redirectedDesktop);
  });

  test('rejects an empty Windows known-folder path', () {
    expect(
      () => WindowsDesktopDirectory.resolve(knownFolderLookup: () => '  '),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('无法获取 Windows 桌面路径'),
        ),
      ),
    );
  });

  test(
    'real Windows known-folder lookup returns the current Desktop directory',
    () {
      final desktop = WindowsDesktopDirectory.resolve();

      expect(desktop.path.trim(), isNotEmpty);
      expect(desktop.existsSync(), isTrue);
    },
    skip: Platform.isWindows ? false : 'Windows Known Folder API is required',
  );
}

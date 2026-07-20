import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

typedef WindowsKnownFolderLookup = String Function();

/// Resolves the current user's real Windows Desktop folder, including
/// OneDrive and administrator-configured folder redirection.
class WindowsDesktopDirectory {
  const WindowsDesktopDirectory._();

  static Directory resolve({
    WindowsKnownFolderLookup? knownFolderLookup,
  }) {
    final path = (knownFolderLookup ?? _lookupWithWindowsApi)().trim();
    if (path.isEmpty) {
      throw StateError('无法获取 Windows 桌面路径，更新已取消');
    }
    return Directory(path);
  }

  static String _lookupWithWindowsApi() {
    if (!Platform.isWindows) {
      throw UnsupportedError('仅 Windows 支持将更新安装包保存到桌面');
    }

    final folderId = FOLDERID_Desktop.toNative(allocator: calloc);
    PWSTR? knownFolderPath;
    try {
      knownFolderPath = SHGetKnownFolderPath(
        folderId,
        KF_FLAG_DEFAULT,
        null,
      );
      return knownFolderPath.toDartString();
    } finally {
      if (knownFolderPath != null) CoTaskMemFree(knownFolderPath);
      calloc.free(folderId);
    }
  }
}

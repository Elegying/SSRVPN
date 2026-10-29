import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

class WindowsInstallerIntegrityFailure extends StateError {
  WindowsInstallerIntegrityFailure() : super('安装包校验失败，未启动安装，请重新下载');
}

/// Ask the existing desktop shell to open the installer outside our process job.
/// The installer owns process shutdown, proxy recovery and overwrite rollback.
class WindowsUpdateInstaller {
  static Future<void> open(
    File file,
    String? expectedSha256, {
    String Function()? explorerPath,
    Future<void> Function(String, List<String>)? start,
  }) async {
    try {
      if (expectedSha256 == null ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedSha256) ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          (await sha256.bind(file.openRead()).first).toString() !=
              expectedSha256.toLowerCase()) {
        throw WindowsInstallerIntegrityFailure();
      }
    } catch (_) {
      throw WindowsInstallerIntegrityFailure();
    }
    final explorer = (explorerPath ?? _explorerPath)();
    await (start ?? _start)(explorer, [file.absolute.path]);
  }

  static String _explorerPath() {
    if (!Platform.isWindows ||
        DynamicLibrary.open('user32.dll')
                .lookupFunction<IntPtr Function(), int Function()>(
                    'GetShellWindow')() ==
            0) {
      throw StateError('Windows 桌面不可用，请稍后手动打开桌面安装包');
    }
    final buffer = calloc<Uint16>(32768).cast<Utf16>();
    try {
      final getWindowsDirectory = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Uint32 Function(Pointer<Utf16>, Uint32),
              int Function(Pointer<Utf16>, int)>('GetWindowsDirectoryW');
      final length = getWindowsDirectory(buffer, 32768);
      if (length == 0 || length >= 32768) {
        throw StateError('无法定位 Windows 桌面程序');
      }
      return '${buffer.toDartString()}\\explorer.exe';
    } finally {
      calloc.free(buffer);
    }
  }

  static Future<void> _start(String executable, List<String> arguments) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }
}

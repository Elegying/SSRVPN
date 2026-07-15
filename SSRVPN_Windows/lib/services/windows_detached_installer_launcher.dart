import 'dart:ffi';
import 'dart:io';

class WindowsProcessCommand {
  const WindowsProcessCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

typedef WindowsProcessStarter = Future<void> Function(
  WindowsProcessCommand command,
);
typedef WindowsShellAvailability = bool Function();

typedef _GetShellWindowNative = IntPtr Function();
typedef _GetShellWindowDart = int Function();

class WindowsDetachedInstallerLauncher {
  const WindowsDetachedInstallerLauncher._();

  static WindowsProcessCommand buildLaunchCommand(String installerPath) {
    final path = File(installerPath).absolute.path;
    return WindowsProcessCommand('explorer.exe', [path]);
  }

  static Future<void> launch(
    File installer, {
    WindowsProcessStarter? start,
    WindowsShellAvailability? hasShellWindow,
  }) async {
    final path = installer.absolute.path;
    final shellAvailable = hasShellWindow ?? _hasDesktopShell;
    if (!shellAvailable()) {
      throw StateError(
        'Windows 桌面 Shell 当前不可用，无法安全交接更新安装包：$path\n'
        '请退出 SSRVPN，并手动运行该安装包。',
      );
    }
    final starter = start ?? _startDetached;
    try {
      await starter(buildLaunchCommand(path));
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        StateError(
          '无法启动已验证的更新安装包：$path\n'
          '$error\n'
          '请退出 SSRVPN，并手动运行该安装包。',
        ),
        stackTrace,
      );
    }
  }

  static bool _hasDesktopShell() {
    if (!Platform.isWindows) return false;
    final getShellWindow = DynamicLibrary.open('user32.dll')
        .lookupFunction<_GetShellWindowNative, _GetShellWindowDart>(
      'GetShellWindow',
    );
    return getShellWindow() != 0;
  }

  static Future<void> _startDetached(WindowsProcessCommand command) async {
    await Process.start(
      command.executable,
      command.arguments,
      mode: ProcessStartMode.detached,
    );
  }
}

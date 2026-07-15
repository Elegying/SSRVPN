import 'dart:io';

class WindowsProcessCommand {
  const WindowsProcessCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

typedef WindowsProcessStarter = Future<void> Function(
  WindowsProcessCommand command,
);

class WindowsDetachedInstallerLauncher {
  const WindowsDetachedInstallerLauncher._();

  static List<WindowsProcessCommand> buildLaunchPlan(String installerPath) {
    final path = File(installerPath).absolute.path;
    return [
      WindowsProcessCommand('explorer.exe', [path]),
      WindowsProcessCommand('powershell.exe', [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Start-Process -LiteralPath \$args[0]',
        path,
      ]),
    ];
  }

  static Future<void> launch(
    File installer, {
    WindowsProcessStarter? start,
  }) async {
    final starter = start ?? _startDetached;
    Object? lastError;
    StackTrace? lastStackTrace;

    for (final command in buildLaunchPlan(installer.path)) {
      try {
        await starter(command);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }

    Error.throwWithStackTrace(
      StateError('Could not start installer: $lastError'),
      lastStackTrace ?? StackTrace.current,
    );
  }

  static Future<void> _startDetached(WindowsProcessCommand command) async {
    await Process.start(
      command.executable,
      command.arguments,
      mode: ProcessStartMode.detached,
    );
  }
}

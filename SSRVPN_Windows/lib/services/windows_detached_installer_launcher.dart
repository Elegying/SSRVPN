import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

class WindowsProcessCommand {
  const WindowsProcessCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

typedef WindowsProcessStarter = Future<void> Function(
  WindowsProcessCommand command,
);
typedef WindowsShellAvailability = bool Function();
typedef WindowsInstallerHandoffWaiter = Future<void> Function(
  File statusFile,
  String token,
);
typedef WindowsInstallerHandoffToken = String Function();

typedef _GetShellWindowNative = IntPtr Function();
typedef _GetShellWindowDart = int Function();
typedef _CreateEventNative = IntPtr Function(
  Pointer<Void>,
  Int32,
  Int32,
  Pointer<Utf16>,
);
typedef _CreateEventDart = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Utf16>,
);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

class WindowsDetachedInstallerLauncher {
  const WindowsDetachedInstallerLauncher._();

  static const String handoffRequestSuffix = '.ssrvpn-handoff';
  static const String handoffStatusSuffix = '.ssrvpn-handoff-status';

  static WindowsProcessCommand buildLaunchCommand(String installerPath) {
    final path = File(installerPath).absolute.path;
    return WindowsProcessCommand('explorer.exe', [path]);
  }

  static Future<void> launch(
    File installer, {
    WindowsProcessStarter? start,
    WindowsShellAvailability? hasShellWindow,
    WindowsInstallerHandoffWaiter? waitForHandoff,
    WindowsInstallerHandoffToken? createToken,
    Duration handoffTimeout = const Duration(minutes: 10),
    Duration handoffPollInterval = const Duration(milliseconds: 100),
  }) async {
    final path = installer.absolute.path;
    final requestFile = File('$path$handoffRequestSuffix');
    final statusFile = File('$path$handoffStatusSuffix');
    final token = (createToken ?? _createHandoffToken)();
    final shellAvailable = hasShellWindow ?? _hasDesktopShell;
    if (!shellAvailable()) {
      throw StateError(
        'Windows 桌面 Shell 当前不可用，无法安全交接更新安装包：$path\n'
        '请退出 SSRVPN，并手动运行该安装包。',
      );
    }
    final lease = _WindowsUpdateHandoffLease.create(token);
    final starter = start ?? _startDetached;
    var handoffCompleted = false;
    try {
      final oldRequestCleaned = await _deleteIfExists(requestFile);
      final oldStatusCleaned = await _deleteIfExists(statusFile);
      if (!oldRequestCleaned || !oldStatusCleaned) {
        throw StateError('无法清理旧的更新安装器交接标记');
      }
      await requestFile.writeAsString(token, flush: true);
      await starter(buildLaunchCommand(path));
      if (waitForHandoff != null) {
        await waitForHandoff(statusFile, token);
      } else {
        await _waitForHandoff(
          statusFile,
          token,
          timeout: handoffTimeout,
          pollInterval: handoffPollInterval,
        );
      }
      handoffCompleted = true;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        StateError(
          '无法启动已验证的更新安装包：$path\n'
          '$error\n'
          '请退出 SSRVPN，并手动运行该安装包。',
        ),
        stackTrace,
      );
    } finally {
      var markersCleaned = false;
      try {
        final requestCleaned = await _deleteIfExists(requestFile);
        final statusCleaned = await _deleteIfExists(statusFile);
        markersCleaned = requestCleaned && statusCleaned;
      } finally {
        lease.close();
      }
      if (handoffCompleted && !markersCleaned) {
        throw StateError('更新安装器已接管，但交接标记清理失败，SSRVPN 保持运行');
      }
    }
  }

  static String _createHandoffToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Future<void> _waitForHandoff(
    File statusFile,
    String token, {
    required Duration timeout,
    required Duration pollInterval,
  }) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < timeout) {
      try {
        if (await statusFile.exists()) {
          final status = await statusFile.readAsString();
          if (status == 'ready:$token') return;
          if (status == 'cancelled:$token') {
            throw StateError('更新安装已取消，SSRVPN 保持运行');
          }
        }
      } on FileSystemException {
        // The installer may be replacing the tiny status file atomically.
      }
      await Future<void>.delayed(pollInterval);
    }
    throw TimeoutException('等待更新安装器接管超时，SSRVPN 保持运行');
  }

  static Future<bool> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
      return true;
    } on FileSystemException {
      return false;
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

class _WindowsUpdateHandoffLease {
  _WindowsUpdateHandoffLease(this._handle);

  int _handle;

  static _WindowsUpdateHandoffLease create(String token) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createEvent = kernel32
        .lookupFunction<_CreateEventNative, _CreateEventDart>('CreateEventW');
    final name = 'Local\\SSRVPN_UpdateHandoff_$token'.toNativeUtf16();
    try {
      final handle = createEvent(nullptr, 1, 0, name);
      if (handle == 0) {
        throw StateError('无法建立更新安装器交接保护');
      }
      return _WindowsUpdateHandoffLease(handle);
    } finally {
      calloc.free(name);
    }
  }

  void close() {
    if (_handle == 0) return;
    DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle')(
      _handle,
    );
    _handle = 0;
  }
}

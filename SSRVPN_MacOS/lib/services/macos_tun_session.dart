import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

typedef TunRouteProbe = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

typedef TunAuthorizationLauncher = Future<TunAuthorizationHandle> Function(
  String executable,
  List<String> arguments,
);

class TunAuthorizationHandle {
  TunAuthorizationHandle({
    required this.exitCode,
    required this.terminate,
  });

  final Future<int> exitCode;
  final void Function() terminate;
}

enum MacosTunStartupState { pending, starting, running, failed }

class _MacosTunStartCancelled implements Exception {}

class _AuthorizationLaunchCancelled {
  const _AuthorizationLaunchCancelled();
}

/// Starts one privileged Mihomo TUN session through the macOS authorization
/// dialog. The application never receives or stores the administrator password.
class MacosTunSession {
  MacosTunSession({
    required this.dataDir,
    String? resolvedExecutable,
    String? runnerPath,
    String? statusPath,
    int? appPid,
    TunRouteProbe? routeProbe,
    TunAuthorizationLauncher? authorizationLauncher,
  })  : resolvedExecutable = resolvedExecutable ?? Platform.resolvedExecutable,
        appPid = appPid ?? pid,
        _routeProbe = routeProbe ?? Process.run,
        _authorizationLauncher =
            authorizationLauncher ?? _launchAuthorizationProcess,
        statusPath =
            statusPath ?? '/var/run/ssrvpn-tun-status-${appPid ?? pid}',
        runnerPath = runnerPath ??
            _defaultRunnerPath(
              resolvedExecutable ?? Platform.resolvedExecutable,
            );

  static const _osascriptPath = '/usr/bin/osascript';
  static const _requestName = '.tun-session-request';
  static const _runnerSha256 =
      'b2494ee09d9a7c03dd7292285d23e6a5e41c33cd977672c204084efacb628833';
  static const _coreArchiveSha256 =
      '3617c9d8a5a55aecfe1ebd0f55ff59f2706c8ad68fd65c6c4e5f7cf2b74263f1';
  static const _coreManifestSha256 =
      '7dbe93c9b2f05b4761898dbb0980c16b2abc73a0e785aeede186972fd0294f51';
  static const _privilegedLauncherScript = r'''
set -euo pipefail
runner_source=$1
core_source=$2
manifest_source=$3
config_source=$4
expected_runner=$5
expected_core=$6
expected_manifest=$7
expected_config=$8
app_pid=$9
stage=/var/run/ssrvpn-tun-launch-$app_pid
[[ ! -e $stage && ! -L $stage ]] || exit 73
/bin/mkdir -m 700 "$stage"
cleanup() { /bin/rm -rf "$stage"; }
trap cleanup EXIT INT TERM HUP
for source in "$runner_source" "$core_source" "$manifest_source" "$config_source"; do
  [[ -f $source && ! -L $source ]] || exit 74
done
/bin/cp "$runner_source" "$stage/macos_tun_runner.sh"
/bin/cp "$core_source" "$stage/AtlasCore.gz"
/bin/cp "$manifest_source" "$stage/AtlasCore-source.txt"
/bin/cp "$config_source" "$stage/config.yaml"
/bin/chmod 700 "$stage/macos_tun_runner.sh"
/bin/chmod 600 "$stage/AtlasCore.gz" "$stage/AtlasCore-source.txt" "$stage/config.yaml"
check_hash() {
  local path=$1
  local expected=$2
  local actual
  actual=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')
  [[ $actual == "$expected" ]] || exit 74
}
check_hash "$stage/macos_tun_runner.sh" "$expected_runner"
check_hash "$stage/AtlasCore.gz" "$expected_core"
check_hash "$stage/AtlasCore-source.txt" "$expected_manifest"
check_hash "$stage/config.yaml" "$expected_config"
/bin/bash "$stage/macos_tun_runner.sh" --app-pid "$app_pid" \
  --staged-config "$stage/config.yaml"
''';

  final String dataDir;
  final String resolvedExecutable;
  final String runnerPath;
  final String statusPath;
  final int appPid;
  final TunRouteProbe _routeProbe;
  final TunAuthorizationLauncher _authorizationLauncher;

  String? lastError;
  bool _requested = false;
  TunAuthorizationHandle? _authorizationHandle;
  DateTime? _statusNotBefore;
  int _startEpoch = 0;
  Completer<void>? _startCancellation;
  Future<void>? _interruptCleanup;

  String get requestPath => '$dataDir${Platform.pathSeparator}$_requestName';
  bool get isRequested => _requested;

  Future<bool> start() async {
    final startEpoch = ++_startEpoch;
    final cancellation = Completer<void>();
    _startCancellation = cancellation;
    lastError = null;
    try {
      final priorCleanup = _interruptCleanup;
      if (priorCleanup != null) await priorCleanup;
      _ensureStartCurrent(startEpoch);
      if (!_isInstalledApplication(resolvedExecutable)) {
        lastError = '请先把 SSRVPN 拖到 Applications 文件夹，再开启 TUN 模式';
        return false;
      }
      if (await FileSystemEntity.type(runnerPath, followLinks: false) !=
          FileSystemEntityType.file) {
        _ensureStartCurrent(startEpoch);
        lastError = 'TUN 授权组件缺失，请重新安装 SSRVPN';
        return false;
      }
      _ensureStartCurrent(startEpoch);
      final assetDirectory = File(runnerPath).parent.path;
      final coreArchivePath = '$assetDirectory/AtlasCore.gz';
      final coreManifestPath = '$assetDirectory/AtlasCore-source.txt';
      for (final path in [coreArchivePath, coreManifestPath]) {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          _ensureStartCurrent(startEpoch);
          lastError = 'TUN 核心资源缺失，请重新安装 SSRVPN';
          return false;
        }
        _ensureStartCurrent(startEpoch);
      }
      final configPath = '$dataDir${Platform.pathSeparator}config.yaml';
      if (await FileSystemEntity.type(configPath, followLinks: false) !=
          FileSystemEntityType.file) {
        _ensureStartCurrent(startEpoch);
        lastError = 'TUN 配置缺失，请重新连接';
        return false;
      }
      _ensureStartCurrent(startEpoch);
      if (await FileSystemEntity.type(dataDir, followLinks: false) !=
          FileSystemEntityType.directory) {
        _ensureStartCurrent(startEpoch);
        lastError = 'TUN 数据目录无效';
        return false;
      }
      _ensureStartCurrent(startEpoch);
      if (await _hasConflictingDefaultTunnel(startEpoch)) {
        _ensureStartCurrent(startEpoch);
        lastError ??= '检测到其他 VPN/TUN 正在接管网络，请先断开后再连接';
        return false;
      }
      _ensureStartCurrent(startEpoch);

      final request = File(requestPath);
      final configSha256 = crypto.sha256.convert(
        await File(configPath).readAsBytes(),
      );
      _ensureStartCurrent(startEpoch);
      await request.writeAsString('$appPid\n', flush: true);
      _ensureStartCurrent(startEpoch);
      final command = '/bin/bash -c '
          '${_shellQuote(_privilegedLauncherScript)} ssrvpn-tun-launch '
          '${_shellQuote(runnerPath)} '
          '${_shellQuote(coreArchivePath)} '
          '${_shellQuote(coreManifestPath)} '
          '${_shellQuote(configPath)} '
          '$_runnerSha256 $_coreArchiveSha256 $_coreManifestSha256 '
          '$configSha256 '
          '$appPid 2>&1';
      final appleScript = 'do shell script "${_appleScriptEscape(command)}" '
          'with administrator privileges '
          'with prompt "SSRVPN 需要管理员授权以启用本次 TUN 连接"';
      _statusNotBefore = DateTime.now().subtract(const Duration(seconds: 1));
      final launch = _authorizationLauncher(
        _osascriptPath,
        ['-e', appleScript],
      );
      final launchResult = await Future.any<Object>([
        launch,
        cancellation.future.then<Object>(
          (_) => const _AuthorizationLaunchCancelled(),
        ),
      ]);
      if (launchResult is _AuthorizationLaunchCancelled) {
        unawaited(
          launch.then<void>(
            (lateHandle) => lateHandle.terminate(),
            onError: (_, __) {},
          ),
        );
        throw _MacosTunStartCancelled();
      }
      final handle = launchResult as TunAuthorizationHandle;
      _authorizationHandle = handle;
      _ensureStartCurrent(startEpoch);
      int? exitCode;
      unawaited(handle.exitCode.then((value) => exitCode = value));
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (DateTime.now().isBefore(deadline)) {
        _ensureStartCurrent(startEpoch);
        final state = await startupState();
        _ensureStartCurrent(startEpoch);
        if (state == MacosTunStartupState.starting ||
            state == MacosTunStartupState.running) {
          _requested = true;
          return true;
        }
        if (state == MacosTunStartupState.failed) {
          await _removeRequest();
          return false;
        }
        if (exitCode != null) {
          await _removeRequest();
          lastError = exitCode == 0 ? 'TUN 授权会话已结束，请重试' : 'TUN 模式需要管理员授权，已取消';
          return false;
        }
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 100)),
          cancellation.future,
        ]);
      }
      _ensureStartCurrent(startEpoch);
      await _removeRequest();
      handle.terminate();
      lastError = '等待管理员授权超过 2 分钟，请重试';
      return false;
    } on _MacosTunStartCancelled {
      await _removeRequest();
      final handle = _authorizationHandle;
      if (!_requested && handle != null) {
        handle.terminate();
        _authorizationHandle = null;
      }
      lastError = 'TUN 连接已取消';
      return false;
    } catch (_) {
      await _removeRequest();
      lastError = '无法打开 macOS 管理员授权窗口';
      return false;
    } finally {
      if (identical(_startCancellation, cancellation)) {
        _startCancellation = null;
      }
    }
  }

  /// Cancels authorization/startup synchronously so queued teardown can run.
  void interruptPendingStart() {
    _startEpoch++;
    final cancellation = _startCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    final handle = _authorizationHandle;
    if (!_requested && handle != null) {
      handle.terminate();
      _authorizationHandle = null;
    }
    final cleanup = _removeRequest();
    _interruptCleanup = cleanup;
    unawaited(
      cleanup.whenComplete(() {
        if (identical(_interruptCleanup, cleanup)) {
          _interruptCleanup = null;
        }
      }),
    );
  }

  Future<void> stop() async {
    final wasRequested = _requested;
    _requested = false;
    await _removeRequest();
    final handle = _authorizationHandle;
    _authorizationHandle = null;
    if (handle == null) return;
    if (!wasRequested) {
      handle.terminate();
      return;
    }
    try {
      await handle.exitCode.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      handle.terminate();
    }
  }

  Future<void> clearStaleRequest() => _removeRequest();

  /// Reads the root-owned runner status without following links. Only a small,
  /// fixed vocabulary is accepted so privileged logs, node names and secrets
  /// can never be reflected into the application UI.
  Future<MacosTunStartupState> startupState() async {
    try {
      if (await FileSystemEntity.type(statusPath, followLinks: false) !=
          FileSystemEntityType.file) {
        return MacosTunStartupState.pending;
      }
      final file = File(statusPath);
      final notBefore = _statusNotBefore;
      if (notBefore != null &&
          (await file.stat()).modified.isBefore(notBefore)) {
        return MacosTunStartupState.pending;
      }
      if (await file.length() > 64) return MacosTunStartupState.pending;
      final value = (await file.readAsString()).trim();
      switch (value) {
        case 'starting':
          return MacosTunStartupState.starting;
        case 'running':
          return MacosTunStartupState.running;
        case 'error:permission':
          lastError = 'TUN 核心权限不足，请重新授权后重试';
          return MacosTunStartupState.failed;
        case 'error:port':
          lastError = 'TUN 核心端口被其他程序占用，请关闭冲突程序后重试';
          return MacosTunStartupState.failed;
        case 'error:tun':
          lastError = 'TUN 网卡或路由创建失败，请重启电脑后重试';
          return MacosTunStartupState.failed;
        case 'error:dns':
          lastError = 'TUN DNS 接管或恢复失败，请断开后重试';
          return MacosTunStartupState.failed;
        case 'error:core':
          lastError = 'TUN 核心启动失败，请查看运行日志';
          return MacosTunStartupState.failed;
        case 'error:timeout':
          lastError = 'TUN 配置校验超时，请检查订阅配置后重试';
          return MacosTunStartupState.failed;
        case 'error:runner':
          lastError = 'TUN 授权组件启动失败，请重新安装 SSRVPN';
          return MacosTunStartupState.failed;
      }
    } catch (_) {}
    return MacosTunStartupState.pending;
  }

  Future<void> _removeRequest() async {
    final request = File(requestPath);
    try {
      if (await request.exists()) await request.delete();
    } catch (_) {}
  }

  Future<bool> _hasConflictingDefaultTunnel(int startEpoch) async {
    for (final arguments in const [
      ['-n', 'get', 'default'],
      ['-n', 'get', '-inet6', 'default'],
    ]) {
      try {
        final result = await _routeProbe(
          '/sbin/route',
          arguments,
        ).timeout(const Duration(seconds: 3));
        _ensureStartCurrent(startEpoch);
        if (result.exitCode == 0 &&
            RegExp(r'^\s*interface:\s*utun\d+\s*$', multiLine: true)
                .hasMatch(result.stdout.toString())) {
          return true;
        }
      } on _MacosTunStartCancelled {
        rethrow;
      } catch (_) {
        lastError = '无法确认现有 VPN 路由状态，请稍后重试';
        return true;
      }
    }
    return false;
  }

  void _ensureStartCurrent(int startEpoch) {
    if (startEpoch != _startEpoch) throw _MacosTunStartCancelled();
  }

  static Future<TunAuthorizationHandle> _launchAuthorizationProcess(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(executable, arguments);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    return TunAuthorizationHandle(
      exitCode: process.exitCode,
      terminate: () => process.kill(ProcessSignal.sigterm),
    );
  }

  static bool _isInstalledApplication(String executable) =>
      executable.startsWith('/Applications/') &&
      executable.contains('.app/Contents/MacOS/');

  static String _defaultRunnerPath(String executable) {
    final contents = File(executable).parent.parent.path;
    return '$contents/Frameworks/App.framework/Resources/'
        'flutter_assets/assets/macos_tun_runner.sh';
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static String _appleScriptEscape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

import 'macos_tun_request_store.dart';

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

class _MacosTunRecoveryCancelled implements Exception {}

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
    Duration stopTimeout = const Duration(seconds: 15),
    TunRouteProbe? routeProbe,
    TunAuthorizationLauncher? authorizationLauncher,
  })  : resolvedExecutable = resolvedExecutable ?? Platform.resolvedExecutable,
        appPid = appPid ?? pid,
        _stopTimeout = stopTimeout,
        _routeProbe = routeProbe ?? Process.run,
        _requestStore = MacosTunRequestStore(
          dataDir: dataDir,
          appPid: appPid ?? pid,
        ),
        _authorizationLauncher =
            authorizationLauncher ?? _launchAuthorizationProcess,
        statusPath =
            statusPath ?? '/var/run/ssrvpn-tun-status-${appPid ?? pid}',
        runnerPath = runnerPath ??
            _defaultRunnerPath(
              resolvedExecutable ?? Platform.resolvedExecutable,
            );

  static const _osascriptPath = '/usr/bin/osascript';
  static const _runnerSha256 =
      'a1c5748f62c061686a8ebc3881c8f4b97c258323cf8f2cbad02ad0277d63f3f6';
  static const _coreArchiveSha256 =
      '4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca';
  static const _coreManifestSha256 =
      '4b96479ee77e07195bb662312d734699dd5b77e88df2f69ad697999a50749bc9';
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
request_token=${10}
[[ $request_token =~ ^v2:active:[0-9]+:[0-9a-f]{32}$ ]] || exit 74
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
  --staged-config "$stage/config.yaml" --request-token "$request_token"
''';
  static const _privilegedRecoveryScript = r'''
set -euo pipefail
runner_source=$1
expected_runner=$2
app_pid=$3
stage=/var/run/ssrvpn-tun-recovery-$app_pid
[[ ! -e $stage && ! -L $stage ]] || exit 73
/bin/mkdir -m 700 "$stage"
cleanup() { /bin/rm -rf "$stage"; }
trap cleanup EXIT INT TERM HUP
[[ -f $runner_source && ! -L $runner_source ]] || exit 74
/bin/cp "$runner_source" "$stage/macos_tun_runner.sh"
/bin/chmod 700 "$stage/macos_tun_runner.sh"
actual=$(/usr/bin/shasum -a 256 "$stage/macos_tun_runner.sh" | \
  /usr/bin/awk '{print $1}')
[[ $actual == "$expected_runner" ]] || exit 74
/bin/bash "$stage/macos_tun_runner.sh" --recover-dns --app-pid "$app_pid"
''';

  final String dataDir;
  final String resolvedExecutable;
  final String runnerPath;
  final String statusPath;
  final int appPid;
  final TunRouteProbe _routeProbe;
  final MacosTunRequestStore _requestStore;
  final TunAuthorizationLauncher _authorizationLauncher;
  final Duration _stopTimeout;

  String? lastError;
  bool _requested = false;
  bool _dnsRecoveryRequired = false;
  bool _markerCleanupFailed = false;
  String? _requestNonce;
  TunAuthorizationHandle? _authorizationHandle;
  int? _authorizationExitCode;
  bool _stopRequested = false;
  DateTime? _statusNotBefore;
  int _startEpoch = 0;
  Completer<void>? _startCancellation;
  Future<void>? _interruptCleanup;
  int _recoveryEpoch = 0;
  Completer<void>? _recoveryCancellation;
  TunAuthorizationHandle? _recoveryAuthorizationHandle;

  String get requestPath => _requestStore.requestPath;
  bool get isRequested => _requested;
  bool get requiresDnsRecovery => _dnsRecoveryRequired;

  Future<bool> hasDurableDnsRecoveryHandoff() async {
    if (!_dnsRecoveryRequired || _markerCleanupFailed) return false;
    final requestNonce = _requestNonce;
    if (requestNonce == null ||
        !await _currentGenerationRequestExists(requestNonce)) {
      return false;
    }
    if (await FileSystemEntity.type(statusPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final status = File(statusPath);
    final notBefore = _statusNotBefore;
    if (notBefore != null &&
        (await status.stat()).modified.isBefore(notBefore)) {
      return false;
    }
    if (await status.length() > 64) return false;
    return (await status.readAsString()).trim() == 'error:dns-recovery';
  }

  List<String> get _recoveryRequestPaths => _requestStore.recoveryRequestPaths;

  Future<bool> start() async {
    final startEpoch = ++_startEpoch;
    final cancellation = Completer<void>();
    String? requestNonce;
    TunAuthorizationHandle? startHandle;
    _startCancellation = cancellation;
    lastError = null;
    _dnsRecoveryRequired = false;
    _markerCleanupFailed = false;
    _authorizationExitCode = null;
    _stopRequested = false;
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
      if (!await recoverStaleDnsIfNeeded()) {
        _ensureStartCurrent(startEpoch);
        return false;
      }
      _ensureStartCurrent(startEpoch);
      if (await _hasConflictingDefaultTunnel(startEpoch)) {
        _ensureStartCurrent(startEpoch);
        lastError ??= '检测到其他 VPN/TUN 正在接管网络，请先断开后再连接';
        return false;
      }
      _ensureStartCurrent(startEpoch);

      requestNonce = _newRequestNonce();
      _requestNonce = requestNonce;
      final activeRequest = _requestValue('active', requestNonce);
      final configSha256 = crypto.sha256.convert(
        await File(configPath).readAsBytes(),
      );
      _ensureStartCurrent(startEpoch);
      await _writeRequestAtomically(activeRequest, requestNonce);
      _ensureStartCurrent(startEpoch);
      final command = '/bin/bash -c '
          '${_shellQuote(_privilegedLauncherScript)} ssrvpn-tun-launch '
          '${_shellQuote(runnerPath)} '
          '${_shellQuote(coreArchivePath)} '
          '${_shellQuote(coreManifestPath)} '
          '${_shellQuote(configPath)} '
          '$_runnerSha256 $_coreArchiveSha256 $_coreManifestSha256 '
          '$configSha256 '
          '$appPid ${_shellQuote(activeRequest)} 2>&1';
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
      startHandle = handle;
      try {
        _ensureStartCurrent(startEpoch);
      } on _MacosTunStartCancelled {
        handle.terminate();
        rethrow;
      }
      _authorizationHandle = handle;
      int? exitCode;
      unawaited(
        handle.exitCode.then((value) {
          exitCode = value;
          if (identical(_authorizationHandle, handle)) {
            _authorizationExitCode = value;
          }
        }),
      );
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
          if (_dnsRecoveryRequired) {
            await _transitionRequestToRecovery(requestNonce);
            _requested = true;
          }
          return false;
        }
        if (exitCode != null) {
          await _removeCurrentGenerationRequest(requestNonce);
          lastError = exitCode == 0 ? 'TUN 授权会话已结束，请重试' : 'TUN 模式需要管理员授权，已取消';
          return false;
        }
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 100)),
          cancellation.future,
        ]);
      }
      _ensureStartCurrent(startEpoch);
      await _removeCurrentGenerationRequest(requestNonce);
      handle.terminate();
      lastError = '等待管理员授权超过 2 分钟，请重试';
      return false;
    } on _MacosTunStartCancelled {
      await _removeCurrentGenerationRequest(requestNonce);
      final handle = startHandle;
      if (!_requested &&
          handle != null &&
          identical(_authorizationHandle, handle)) {
        handle.terminate();
        _authorizationHandle = null;
        _authorizationExitCode = null;
      }
      if (requestNonce == null || _requestNonce == requestNonce) {
        lastError = 'TUN 连接已取消';
      }
      return false;
    } catch (_) {
      await _removeCurrentGenerationRequest(requestNonce);
      if (requestNonce == null || _requestNonce == requestNonce) {
        lastError = '无法打开 macOS 管理员授权窗口';
      }
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
    _recoveryEpoch++;
    final recoveryCancellation = _recoveryCancellation;
    final recoveryWasPending = recoveryCancellation != null;
    if (recoveryCancellation != null && !recoveryCancellation.isCompleted) {
      recoveryCancellation.complete();
    }
    final recoveryHandle = _recoveryAuthorizationHandle;
    if (recoveryHandle != null) {
      _terminateAuthorizationHandle(recoveryHandle);
      if (identical(_recoveryAuthorizationHandle, recoveryHandle)) {
        _recoveryAuthorizationHandle = null;
      }
    }
    if (recoveryWasPending) {
      lastError = 'TUN DNS 恢复已取消，已保留恢复标记';
    }
    if (!_requested && !recoveryWasPending) {
      final cleanup = _removeCurrentGenerationRequest(_requestNonce);
      _interruptCleanup = cleanup;
      unawaited(
        cleanup.whenComplete(() {
          if (identical(_interruptCleanup, cleanup)) {
            _interruptCleanup = null;
          }
        }),
      );
    }
  }

  Future<void> stop() async {
    final wasRequested = _requested;
    final handle = _authorizationHandle;
    final requestNonce = _requestNonce;
    if (handle == null) {
      if (wasRequested) {
        lastError = 'TUN 授权会话状态不完整，已保留恢复标记';
        throw StateError(lastError!);
      }
      return;
    }
    _stopRequested = true;
    try {
      if (!await _transitionRequestToRecovery(requestNonce)) {
        if (await _finishAlreadyRetiredSession(handle, requestNonce)) return;
        _dnsRecoveryRequired = true;
        lastError = '无法持久化 TUN DNS 恢复标记，已保留当前授权会话';
        throw StateError(lastError!);
      }
      int exitCode;
      try {
        exitCode = await handle.exitCode.timeout(_stopTimeout);
      } on TimeoutException {
        _dnsRecoveryRequired = true;
        lastError = 'TUN 授权会话停止超时，已保留 DNS 恢复标记';
        throw StateError(lastError!);
      }

      final state = await startupState();
      final ownedMarkerRemains =
          await _currentGenerationRequestExists(requestNonce);
      if (identical(_authorizationHandle, handle) &&
          _requestNonce == requestNonce) {
        _authorizationHandle = null;
        _authorizationExitCode = null;
        _requested = false;
        if (!ownedMarkerRemains) _requestNonce = null;
      }
      if (exitCode != 0 || state == MacosTunStartupState.failed) {
        if (_dnsRecoveryRequired ||
            (ownedMarkerRemains && !_markerCleanupFailed)) {
          _dnsRecoveryRequired = true;
          lastError ??= 'TUN 授权会话未能安全停止，已保留 DNS 恢复标记';
        } else {
          _dnsRecoveryRequired = false;
          lastError ??= 'TUN 授权会话停止失败，请修复问题后重试';
        }
        throw StateError(lastError!);
      }
      if (ownedMarkerRemains) {
        lastError = 'TUN 已停止，但特权会话标记未能安全退役';
        throw StateError(lastError!);
      }
      _dnsRecoveryRequired = false;
      _markerCleanupFailed = false;
    } finally {
      _stopRequested = false;
    }
  }

  Future<bool> _finishAlreadyRetiredSession(
    TunAuthorizationHandle handle,
    String? requestNonce,
  ) async {
    if (requestNonce == null ||
        !identical(_authorizationHandle, handle) ||
        _requestNonce != requestNonce) {
      return false;
    }
    final requestType =
        await FileSystemEntity.type(requestPath, followLinks: false);
    if (requestType != FileSystemEntityType.notFound) {
      return false;
    }
    if (_authorizationExitCode == null) {
      try {
        await handle.exitCode.timeout(_stopTimeout);
      } on TimeoutException {
        return false;
      }
    }
    final statusType =
        await FileSystemEntity.type(statusPath, followLinks: false);
    if (statusType != FileSystemEntityType.notFound) {
      if (statusType != FileSystemEntityType.file) return false;
      final status = File(statusPath);
      final notBefore = _statusNotBefore;
      final stat = await status.stat();
      if ((notBefore != null && stat.modified.isBefore(notBefore)) ||
          await status.length() > 64 ||
          (await status.readAsString()).trim() != 'error:network-change') {
        return false;
      }
    }
    if (!identical(_authorizationHandle, handle) ||
        _requestNonce != requestNonce) {
      return false;
    }
    _authorizationHandle = null;
    _authorizationExitCode = null;
    _requestNonce = null;
    _requested = false;
    _dnsRecoveryRequired = false;
    _markerCleanupFailed = false;
    lastError = null;
    return true;
  }

  Future<bool> recoverStaleDnsIfNeeded() async {
    final previousCancellation = _recoveryCancellation;
    if (previousCancellation != null && !previousCancellation.isCompleted) {
      previousCancellation.complete();
    }
    final previousHandle = _recoveryAuthorizationHandle;
    if (previousHandle != null) {
      _terminateAuthorizationHandle(previousHandle);
      if (identical(_recoveryAuthorizationHandle, previousHandle)) {
        _recoveryAuthorizationHandle = null;
      }
    }
    final recoveryEpoch = ++_recoveryEpoch;
    final cancellation = Completer<void>();
    _recoveryCancellation = cancellation;
    TunAuthorizationHandle? handle;
    try {
      final recoveryRequestPaths = _recoveryRequestPaths;
      final recoveryRequests = <String, String>{};
      for (final path in recoveryRequestPaths) {
        final requestType =
            await FileSystemEntity.type(path, followLinks: false);
        _ensureRecoveryCurrent(recoveryEpoch);
        if (requestType == FileSystemEntityType.notFound) continue;
        if (requestType != FileSystemEntityType.file) {
          lastError = '检测到不安全的 TUN 恢复标记，已暂停自动恢复';
          return false;
        }
        final value = await _readRecoveryRequest(path);
        _ensureRecoveryCurrent(recoveryEpoch);
        if (value == null) {
          lastError = '检测到不安全的 TUN 恢复标记，已暂停自动恢复';
          return false;
        }
        recoveryRequests[path] = value;
      }
      if (recoveryRequests.isEmpty) return true;
      if (!_isInstalledApplication(resolvedExecutable)) {
        lastError = '检测到待恢复的 TUN DNS，请先把 SSRVPN 拖到 Applications 文件夹';
        return false;
      }
      final runnerType =
          await FileSystemEntity.type(runnerPath, followLinks: false);
      _ensureRecoveryCurrent(recoveryEpoch);
      if (runnerType != FileSystemEntityType.file) {
        lastError = 'TUN DNS 恢复组件缺失，请重新安装 SSRVPN';
        return false;
      }

      final command = '/bin/bash -c '
          '${_shellQuote(_privilegedRecoveryScript)} ssrvpn-tun-recovery '
          '${_shellQuote(runnerPath)} $_runnerSha256 $appPid 2>&1';
      final appleScript = 'do shell script "${_appleScriptEscape(command)}" '
          'with administrator privileges '
          'with prompt "SSRVPN 检测到上次异常退出，需要恢复 TUN DNS 设置"';
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
            _terminateAuthorizationHandle,
            onError: (_, __) {},
          ),
        );
        throw _MacosTunRecoveryCancelled();
      }
      handle = launchResult as TunAuthorizationHandle;
      try {
        _ensureRecoveryCurrent(recoveryEpoch);
      } on _MacosTunRecoveryCancelled {
        _terminateAuthorizationHandle(handle);
        rethrow;
      }
      _recoveryAuthorizationHandle = handle;
      final exitResult = await Future.any<Object>([
        handle.exitCode.timeout(const Duration(minutes: 2)),
        cancellation.future.then<Object>(
          (_) => const _AuthorizationLaunchCancelled(),
        ),
      ]);
      if (exitResult is _AuthorizationLaunchCancelled) {
        throw _MacosTunRecoveryCancelled();
      }
      _ensureRecoveryCurrent(recoveryEpoch);
      final exitCode = exitResult as int;
      if (exitCode != 0) {
        lastError = 'TUN DNS 启动恢复失败或授权已取消，已保留恢复标记';
        return false;
      }
      for (final entry in recoveryRequests.entries) {
        final type = await FileSystemEntity.type(
          entry.key,
          followLinks: false,
        );
        _ensureRecoveryCurrent(recoveryEpoch);
        if (type == FileSystemEntityType.notFound) continue;
        final current = await _readRecoveryRequest(entry.key);
        _ensureRecoveryCurrent(recoveryEpoch);
        if (current != entry.value) {
          lastError = 'TUN DNS 已恢复，但恢复标记未能清理';
          return false;
        }
        // The privileged runner owns marker retirement under the global TUN
        // lock. An unchanged marker here is evidence that cleanup did not
        // cross its commit point; Dart must never delete it speculatively.
        lastError = 'TUN DNS 已恢复，但特权恢复标记仍存在';
        return false;
      }
      lastError = null;
      return true;
    } on _MacosTunRecoveryCancelled {
      final currentHandle = handle;
      if (currentHandle != null &&
          identical(_recoveryAuthorizationHandle, currentHandle)) {
        _recoveryAuthorizationHandle = null;
        _terminateAuthorizationHandle(currentHandle);
      }
      if (identical(_recoveryCancellation, cancellation)) {
        lastError = 'TUN DNS 恢复已取消，已保留恢复标记';
      }
      return false;
    } on TimeoutException {
      final currentHandle = handle;
      if (currentHandle != null &&
          identical(_recoveryAuthorizationHandle, currentHandle)) {
        _recoveryAuthorizationHandle = null;
        _terminateAuthorizationHandle(currentHandle);
      }
      if (identical(_recoveryCancellation, cancellation)) {
        lastError = 'TUN DNS 启动恢复授权超时，已保留恢复标记';
      }
      return false;
    } catch (_) {
      if (identical(_recoveryCancellation, cancellation)) {
        lastError = '无法启动 TUN DNS 恢复授权，已保留恢复标记';
      }
      return false;
    } finally {
      if (handle != null && identical(_recoveryAuthorizationHandle, handle)) {
        _recoveryAuthorizationHandle = null;
      }
      if (identical(_recoveryCancellation, cancellation)) {
        _recoveryCancellation = null;
      }
    }
  }

  Future<void> clearStaleRequest() => _removeRequest();

  /// Reads the root-owned runner status without following links. Only a small,
  /// fixed vocabulary is accepted so privileged logs, node names and secrets
  /// can never be reflected into the application UI.
  Future<MacosTunStartupState> startupState() async {
    final authorizationExitCode = _authorizationExitCode;
    if (_requested && !_stopRequested && authorizationExitCode != null) {
      lastError = 'TUN 授权会话已退出（退出码 $authorizationExitCode），核心服务不再受本次会话管理';
      return MacosTunStartupState.failed;
    }
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
          lastError = 'TUN DNS 接管失败，请稍后重试';
          return MacosTunStartupState.failed;
        case 'error:network-change':
          lastError = '检测到物理网络已切换，TUN 已安全停止，请重新连接';
          return MacosTunStartupState.failed;
        case 'error:dns-recovery':
          _dnsRecoveryRequired = true;
          lastError = 'TUN DNS 恢复尚未完成，已保留恢复会话';
          return MacosTunStartupState.failed;
        case 'error:marker':
          _markerCleanupFailed = true;
          lastError = 'TUN 已安全停止，但会话标记清理失败，请重试';
          return MacosTunStartupState.failed;
        case 'error:stale':
          lastError = '检测到上次异常退出的 TUN 会话，请重启 Mac 后重试';
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

  Future<void> _removeRequest() => _requestStore.remove();

  String _requestValue(String phase, String? nonce) =>
      _requestStore.value(phase, nonce);

  Future<void> _writeRequestAtomically(String value, String nonce) =>
      _requestStore.writeAtomically(value, nonce);

  Future<bool> _transitionRequestToRecovery(String? nonce) =>
      _requestStore.transitionToRecovery(nonce);

  Future<void> _removeCurrentGenerationRequest(String? nonce) =>
      _requestStore.removeCurrentGeneration(nonce);

  Future<bool> _currentGenerationRequestExists(String? nonce) =>
      _requestStore.currentGenerationExists(nonce);

  static Future<String?> _readRecoveryRequest(String path) =>
      MacosTunRequestStore.readRecoveryRequest(path);

  static String _newRequestNonce() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  void _ensureRecoveryCurrent(int recoveryEpoch) {
    if (_recoveryEpoch != recoveryEpoch) {
      throw _MacosTunRecoveryCancelled();
    }
  }

  static void _terminateAuthorizationHandle(TunAuthorizationHandle handle) {
    try {
      handle.terminate();
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

part of 'clash_service.dart';

extension _WindowsStartPreparationSupport on _WindowsCoreLifecycle {
  Future<_WindowsExistingRuntimePreparation> _prepareExistingWindowsRuntime(
    int startToken,
  ) async {
    if (isRunning) {
      try {
        if (await healthCheck()) {
          return _WindowsExistingRuntimePreparation.alreadyHealthy;
        }
      } catch (_) {}
      _ensureStartCurrent(startToken);
      final stoppedSafely = await _stopInternal();
      _ensureStartCurrent(startToken);
      if (!stoppedSafely) {
        setLastStartError(_lastStopError ?? '现有 Mihomo 连接无法安全停止，已拒绝启动新的核心');
        log('❌ $lastStartError');
        return _WindowsExistingRuntimePreparation.blocked;
      }
    }
    if (_coreProcess != null) {
      log('检测到尚未确认退出的 Mihomo，正在安全清理...');
      final stoppedSafely = await _stopInternal();
      _ensureStartCurrent(startToken);
      if (!stoppedSafely || _coreProcess != null) {
        setLastStartError(_lastStopError ?? '上一个 Mihomo 进程尚未退出，已拒绝启动新的核心');
        log('❌ $lastStartError');
        return _WindowsExistingRuntimePreparation.blocked;
      }
    }
    if (_tunTeardownGate.shouldProbeBeforeStart(
      enableTun: settings.enableTun,
    )) {
      if (!await _waitForTunTeardown()) {
        _ensureStartCurrent(startToken);
        setLastStartError(_tunResidualProbeError);
        log('❌ $lastStartError');
        return _WindowsExistingRuntimePreparation.blocked;
      }
      _ensureStartCurrent(startToken);
    }
    return _WindowsExistingRuntimePreparation.ready;
  }

  Future<_WindowsLaunchPreparation?> _prepareWindowsLaunch(
    int startToken,
  ) async {
    if (!File(_corePath).existsSync()) {
      log('❌ 核心文件不存在: $_corePath');
      log('请下载 mihomo-windows-amd64 并重命名为 mihomo.exe 放到应用目录');
      setLastStartError('找不到 mihomo.exe，文件可能未完整解压或被安全软件隔离');
      return null;
    }
    if (!File(configPath).existsSync()) {
      log('❌ 配置文件不存在: $configPath');
      setLastStartError('找不到生成的 Mihomo 配置文件');
      return null;
    }
    if (settings.enableTun && !await _confirmWindowsTunElevation(startToken)) {
      return null;
    }

    final tmpDir = '$configDir${Platform.pathSeparator}tmp';
    await Directory(tmpDir).create(recursive: true);
    _ensureStartCurrent(startToken);
    final environment = {'TMPDIR': tmpDir, 'TMP': tmpDir, 'TEMP': tmpDir};
    if (!await validateConfig(environment)) {
      setLastStartError(lastStartError ?? 'Mihomo 配置校验失败，请打开运行日志查看具体配置错误');
      return null;
    }
    _ensureStartCurrent(startToken);
    final pidFile = File('$configDir${Platform.pathSeparator}mihomo.pid');
    final pidFileType = await FileSystemEntity.type(
      pidFile.path,
      followLinks: false,
    );
    if (_corePidRecord != null ||
        pidFileType != FileSystemEntityType.notFound) {
      setLastStartError('检测到尚未安全清理的 Mihomo 进程身份记录，已拒绝启动新的核心');
      log('❌ $lastStartError');
      return null;
    }
    if (_coreProcess != null) {
      setLastStartError('上一个 Mihomo 进程尚未退出，已拒绝启动新的核心');
      log('❌ $lastStartError');
      await _cleanupFailedStart();
      return null;
    }
    if (settings.enableTun &&
        !await _awaitStartOperation(
          _proxyService.isLauncherGuardianReady(
            cancellation: _startCancellation?.future,
          ),
          startToken,
        )) {
      _ensureStartCurrent(startToken);
      setLastStartError(
        '独立崩溃保护进程未就绪，TUN 模式已安全中止；'
        '请通过 ssrvpn_windows.exe 启动或重试',
      );
      log('❌ $lastStartError');
      return null;
    }

    final startedWithTun = settings.enableTun;
    if (startedWithTun) {
      final baselineProbe = _networkInterfaceIdentityProbeOverride;
      _tunInterfacesBeforeStart = await _awaitStartOperation(
        baselineProbe?.call() ??
            probeWindowsNetworkInterfaceIdentities(
              cancellation: _startCancellation?.future,
            ),
        startToken,
      );
    } else {
      _tunInterfacesBeforeStart = const <WindowsTunInterfaceIdentity>{};
    }
    _ensureStartCurrent(startToken);
    if (startedWithTun && !await _armTunTeardownGate()) {
      _tunInterfacesBeforeStart = const <WindowsTunInterfaceIdentity>{};
      _ensureStartCurrent(startToken);
      setLastStartError('无法持久化 TUN 清理状态，已在启动 Mihomo 前安全中止');
      log('❌ $lastStartError');
      return null;
    }
    _ensureStartCurrent(startToken);
    return (environment: environment, startedWithTun: startedWithTun);
  }

  Future<bool> _confirmWindowsTunElevation(int startToken) async {
    final isAdministrator = await _awaitStartOperation(
      _isAdministrator(cancellation: _startCancellation?.future),
      startToken,
    );
    _ensureStartCurrent(startToken);
    if (isAdministrator != true) {
      WindowsTunElevationRequestResult? elevationRequest;
      if (isAdministrator == false) {
        elevationRequest = await _awaitStartOperation(
          _tunElevationService.requestRelaunch(),
          startToken,
        );
        _ensureStartCurrent(startToken);
      }
      if (elevationRequest == WindowsTunElevationRequestResult.launched) {
        _tunElevationRelaunchPending = true;
      }
      setLastStartError(switch (elevationRequest) {
        WindowsTunElevationRequestResult.launched =>
          'TUN 模式需要管理员权限，SSRVPN 正在自动重启并继续连接',
        WindowsTunElevationRequestResult.cancelled => '已取消管理员授权，TUN 模式未启动',
        WindowsTunElevationRequestResult.standardUser =>
          '当前 Windows 账户不能直接提升为管理员；TUN 模式未启动，请使用管理员账户运行 SSRVPN',
        WindowsTunElevationRequestResult.failed =>
          '无法打开管理员授权窗口，TUN 模式未启动，请手动以管理员身份运行 SSRVPN',
        null => '无法确认管理员权限，TUN 模式已安全中止，请重新以管理员身份运行 SSRVPN',
      });
      log('❌ $lastStartError');
      return false;
    }
    return true;
  }
}

part of desktop_home_screen;

extension _DesktopHomeBackgroundTasks on _HomeScreenState {
  Future<void> _loadInitialData() async {
    if (!_canUpdateUi) return;
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    if (!identical(_clashService, clashService)) {
      _clashService?.removeStatusListener(_clashStatusListener);
      _clashService = clashService;
      clashService.addStatusListener(_clashStatusListener);
    }
    final statusEpoch = _connectionStatusEpoch;
    final wasRunning = clashService.isRunning;
    final runtimeSelectedNodeName =
        wasRunning ? await clashService.currentSelectedProxyName() : null;
    if (!_canUpdateUi || !identical(_subscriptionService, subService)) {
      return;
    }
    final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
    final revision = subService.revision;
    final statusIsCurrent = statusEpoch == _connectionStatusEpoch &&
        clashService.isRunning == wasRunning;
    final runtimeSelectedNode = statusIsCurrent && wasRunning
        ? HomeNodeController.resolveRuntimeSelectedNodeFrom(
            nodes,
            runtimeSelectedNodeName,
          )
        : null;
    if (nodes.isNotEmpty) {
      setState(() {
        _nodes = nodes;
        _lastRevision = revision;
        if (statusIsCurrent && wasRunning) {
          _selectedNode = runtimeSelectedNode;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_canUpdateUi ||
            !identical(_subscriptionService, subService) ||
            subService.revision != revision) {
          return;
        }
        unawaited(_runBatchLatencyTest());
      });
    }
    if (statusIsCurrent && wasRunning) {
      setState(() {
        _isConnected = true;
        _connectivityWarning = clashService.connectivityWarning;
      });
      _schedulePublicIpRefresh();
      _checkUpdateDelayed();
    }

    if (nodes.isEmpty) {
      _maybeShowInitialSubscriptionDialog(subService);
    }
  }

  void _handleClashStatusChanged() {
    final clashService = _clashService;
    if (clashService == null || !_canUpdateUi) return;
    final running = clashService.isRunning;
    final connectivityWarning =
        running ? clashService.connectivityWarning : null;
    final cancelledWhileConnecting =
        _isConnecting && !clashService.connectionDesired;
    if (!desktopStatusNotificationChangesState(
      wasConnected: _isConnected,
      isRunning: running,
      previousWarning: _connectivityWarning,
      nextWarning: connectivityWarning,
      cancelledWhileConnecting: cancelledWhileConnecting,
    )) {
      return;
    }
    final statusEpoch = ++_connectionStatusEpoch;
    setState(() {
      _isConnected = running;
      _connectivityWarning = connectivityWarning;
      if (cancelledWhileConnecting) _isConnecting = false;
      if (!running) {
        _latencyController.clear();
        _selectedNode = null;
        _resetPublicIpState();
        _exitCountryResolveGeneration++;
      } else {
        _scheduleExitCountryResolution();
        _schedulePublicIpRefresh();
        unawaited(_syncSelectedNodeFromRuntime(statusEpoch));
      }
    });
    if (running) {
      _checkUpdateDelayed();
    } else {
      _updateCheckTimer?.cancel();
    }
  }

  Future<void> _syncSelectedNodeFromRuntime(int statusEpoch) async {
    final clashService = _clashService;
    if (clashService == null || !_canUpdateUi || !_isConnected) return;
    final runtimeSelectedNode = await _resolveRuntimeSelectedNode(
      clashService,
      _nodes,
    );
    if (!_canUpdateUi ||
        !_isConnected ||
        statusEpoch != _connectionStatusEpoch ||
        !identical(_clashService, clashService)) {
      return;
    }
    setState(() => _selectedNode = runtimeSelectedNode);
  }

  Future<bool> _rememberSelectedNode(ProxyNode node) async {
    final settingsService = context.read<SettingsService>();
    if (settingsService.settings.lastSelectedNodeName == node.name) return true;
    try {
      await settingsService.updateLastSelectedNodeName(node.name);
      return settingsService.settings.lastSelectedNodeName == node.name;
    } catch (error, stack) {
      AppLogger.warning(
        'Settings',
        '保存首选节点失败，不影响当前连接: $error\n$stack',
      );
      return false;
    }
  }

  void _scheduleLatencyFlush(int generation) {
    _latencyBatchTimer?.cancel();
    _latencyBatchTimer = Timer(
      const Duration(milliseconds: 100),
      () => _flushPendingLatencies(generation),
    );
  }

  void _flushPendingLatencies(int generation) {
    if (!_latencyController.hasPending || !_canUpdateUi) return;
    if (_latencyBatchGeneration != generation ||
        !_latencyController.isCurrentBatch(generation)) {
      return;
    }
    setState(() {
      _latencyController.flushBatchTo(generation, _nodes);
    });
  }

  void _cancelLatencyBatch() {
    _latencyBatchTimer?.cancel();
    _singleLatencyGeneration++;
    final generation = _latencyBatchGeneration;
    if (generation != null) _latencyController.cancelBatch(generation);
    _latencyBatchGeneration = null;
    _isBatchTesting = false;
    _testingNodeName = null;
  }

  void _checkUpdateDelayed({
    Duration delay = const Duration(seconds: 10),
  }) {
    if (!_isConnected ||
        _updateCheckCompleted ||
        _updateCheckInProgress ||
        (_updateCheckTimer?.isActive ?? false)) {
      return;
    }
    _updateCheckTimer = Timer(delay, () {
      unawaited(_checkForUpdate());
    });
  }

  Future<void> _checkForUpdate() async {
    if (!_canUpdateUi || !_isConnected || _updateCheckInProgress) {
      return;
    }
    _updateCheckInProgress = true;
    _updateCheckAttempts++;
    var shouldRetry = false;
    try {
      const currentVersion = UpdateService.appVersion;
      final update = await UpdateService.checkForUpdate(currentVersion);
      if (update != null && _canUpdateUi && _isConnected) {
        context.read<UpdateAvailabilityController>().publish(update);
      }
      _updateCheckCompleted = _isConnected;
    } catch (e) {
      shouldRetry = _updateCheckAttempts < 2;
      AppLogger.warning('Update', '检查更新异常: $e');
    } finally {
      _updateCheckInProgress = false;
    }
    if (shouldRetry && _canUpdateUi && _isConnected) {
      _checkUpdateDelayed(delay: const Duration(minutes: 1));
    }
  }

  Future<void> _checkForUpdateManually() async {
    if (!_canUpdateUi) return;
    if (_updateCheckInProgress) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('正在检查更新，请稍候')),
      );
      return;
    }
    _updateCheckTimer?.cancel();
    _updateCheckInProgress = true;
    try {
      const currentVersion = UpdateService.appVersion;
      final update = await UpdateService.checkForUpdate(currentVersion);
      if (!_canUpdateUi) return;
      if (update == null) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('当前已是最新版本')),
        );
        return;
      }
      context.read<UpdateAvailabilityController>().publish(update);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('发现新版本 v${update.version}，请点击底部版本号更新')),
      );
    } catch (error) {
      AppLogger.warning('Update', '手动检查更新异常: $error');
      if (_canUpdateUi) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('检查更新失败，请检查网络后重试')),
        );
      }
    } finally {
      _updateCheckInProgress = false;
    }
  }
}

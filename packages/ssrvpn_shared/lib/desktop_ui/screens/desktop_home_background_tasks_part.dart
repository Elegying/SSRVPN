part of desktop_home_screen;

extension _DesktopHomeBackgroundTasks on _HomeScreenState {
  Future<void> _loadInitialData() async {
    if (!mounted || _disposed) return;
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
    if (!mounted || _disposed || !identical(_subscriptionService, subService)) {
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
        if (!mounted ||
            _disposed ||
            !identical(_subscriptionService, subService) ||
            subService.revision != revision) {
          return;
        }
        unawaited(_autoTestAllNodes());
      });
    }
    if (statusIsCurrent && wasRunning) {
      setState(() {
        _isConnected = true;
        _connectivityWarning = clashService.connectivityWarning;
      });
      _schedulePublicIpRefresh();
    }

    if (nodes.isEmpty) {
      _maybeShowInitialSubscriptionDialog(subService);
    }
  }

  void _handleClashStatusChanged() {
    final clashService = _clashService;
    if (clashService == null || !mounted || _disposed) return;
    final statusEpoch = ++_connectionStatusEpoch;
    final running = clashService.isRunning;
    final connectivityWarning =
        running ? clashService.connectivityWarning : null;
    final cancelledWhileConnecting =
        _isConnecting && !clashService.connectionDesired;
    if (_isConnected == running &&
        _connectivityWarning == connectivityWarning &&
        !cancelledWhileConnecting) {
      return;
    }
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
  }

  Future<void> _syncSelectedNodeFromRuntime(int statusEpoch) async {
    final clashService = _clashService;
    if (clashService == null || !mounted || _disposed || !_isConnected) return;
    final runtimeSelectedNode = await _resolveRuntimeSelectedNode(
      clashService,
      _nodes,
    );
    if (!mounted ||
        _disposed ||
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
    if (!_latencyController.hasPending || !mounted || _disposed) return;
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
    if (_updateCheckCompleted ||
        _updateCheckInProgress ||
        (_updateCheckTimer?.isActive ?? false)) {
      return;
    }
    _updateCheckTimer = Timer(delay, () {
      unawaited(_checkForUpdate());
    });
  }

  Future<void> _checkForUpdate() async {
    if (!mounted || _disposed || _updateCheckInProgress) return;
    _updateCheckInProgress = true;
    _updateCheckAttempts++;
    var shouldRetry = false;
    try {
      const currentVersion = UpdateService.appVersion;
      final update = await UpdateService.checkForUpdate(currentVersion);
      if (update != null && mounted && !_disposed) {
        await UpdateService.showUpdateDialog(
          context,
          latestVersion: update.version,
          currentVersion: currentVersion,
          downloadUrl: update.downloadUrl,
          changelog: update.changelog,
          sha256: update.sha256,
          fallbackDownloadUrl: update.fallbackDownloadUrl,
          prepareForInstall: _prepareForUpdateInstall,
        );
      }
      _updateCheckCompleted = true;
    } catch (e) {
      shouldRetry = _updateCheckAttempts < 2;
      AppLogger.warning('Update', '检查更新异常: $e');
    } finally {
      _updateCheckInProgress = false;
    }
    if (shouldRetry && mounted && !_disposed) {
      _checkUpdateDelayed(delay: const Duration(minutes: 1));
    }
  }

  Future<bool> _prepareForUpdateInstall() async {
    if (!mounted || _disposed) return false;
    final clashService = _clashService ?? context.read<ClashService>();
    if (!clashService.isRunning && !clashService.connectionDesired) return true;

    clashService.requestConnectionIntent(false);
    clashService.interruptPendingStart();
    try {
      await clashService.runConnectionTransition(clashService.stop);
    } catch (error, stack) {
      recordDesktopConnectionFailure(
        '更新前安全断开失败',
        error: error,
        stack: stack,
      );
    }

    final stopped = !clashService.isRunning;
    if (mounted && !_disposed) {
      setState(() {
        _isConnected = clashService.isRunning;
        _isConnecting = false;
        if (stopped) {
          _selectedNode = null;
          _resetPublicIpState();
        } else {
          _errorMessage = '更新前无法安全断开连接，已阻止打开安装包。请先手动断开后重试';
        }
      });
    }
    return stopped;
  }
}

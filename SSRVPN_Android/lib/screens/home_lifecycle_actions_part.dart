part of 'home_screen.dart';

extension _AndroidHomeLifecycleActions on HomeScreenState {
  bool _onSubscriptionChanged(SubscriptionService subService) {
    final controller = HomeNodeController(
      nodes: _nodes,
      latencies: _latencyController.latencies,
      lastRevision: _lastRevision,
      selectedNode: _selectedNode,
    );
    final sync = controller.syncSubscriptionSnapshot(
      revision: subService.revision,
      allNodes: subService.allNodes,
    );
    if (!sync.changed) return false;
    _cancelSingleLatencyTest();
    _cancelLatencyBatch();
    _lastRevision = controller.lastRevision;
    _nodes = controller.nodes;
    if (sync.shouldPromptForImport) return true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      if (!sync.isFirstSync && _isConnected) {
        unawaited(_reloadConfig());
      } else {
        unawaited(_autoTestAllNodes());
      }
    });
    return true;
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
    _updateHomeState(() {
      _latencyController.flushBatchTo(generation, _nodes);
    });
  }

  void _cancelLatencyBatch() {
    _latencyBatchTimer?.cancel();
    final generation = _latencyBatchGeneration;
    if (generation != null) _latencyController.cancelBatch(generation);
    _latencyBatchGeneration = null;
    _isBatchTesting = false;
  }

  void _cancelSingleLatencyTest() {
    _singleLatencyGeneration++;
    _testingNodeName = null;
  }

  Future<void> _loadInitialData() async {
    if (!mounted || _disposed) return;
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    _registeredClashService = clashService;
    clashService.onAutoConnect = _onClashAutoConnect;
    clashService.onStatusChanged = _onClashStatusChanged;

    final statusEpoch = _connectionStatusEpoch;
    final running = clashService.isRunning;
    final queriedRuntimeNodeName =
        running ? await clashService.currentSelectedProxyName() : null;
    if (!mounted ||
        _disposed ||
        !identical(_subscriptionService, subService) ||
        !identical(_registeredClashService, clashService)) {
      return;
    }
    final statusIsCurrent = statusEpoch == _connectionStatusEpoch &&
        clashService.isRunning == running;
    final runtimeSelectedNodeName =
        statusIsCurrent ? queriedRuntimeNodeName : null;
    final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
    final revision = subService.revision;
    if (nodes.isNotEmpty) {
      _updateHomeState(() {
        _nodes = nodes;
        _lastRevision = revision;
        if (statusIsCurrent && running && _selectedNode == null) {
          _selectedNode = HomeNodeController.resolveRuntimeSelectedNodeFrom(
            nodes,
            runtimeSelectedNodeName,
          );
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
    if (statusIsCurrent && running) {
      _updateHomeState(() => _isConnected = true);
      _glowController.repeat();
      _schedulePublicIpRefresh();
    }

    final pendingAutoConnect = await clashService.consumePendingAutoConnect();
    if (pendingAutoConnect &&
        !_isConnected &&
        mounted &&
        !_disposed &&
        identical(_registeredClashService, clashService)) {
      unawaited(_handleConnectToggle());
    }
  }

  void _handleClashAutoConnect() {
    if (!_isConnected && mounted && !_disposed) {
      unawaited(_handleConnectToggle());
    }
  }

  void _handleClashStatusChanged() {
    final clashService = _registeredClashService;
    if (!mounted || _disposed || clashService == null) return;
    final statusEpoch = ++_connectionStatusEpoch;
    unawaited(_applyClashStatusChanged(clashService, statusEpoch));
  }

  Future<void> _applyClashStatusChanged(
    ClashService clashService,
    int statusEpoch,
  ) async {
    final running = clashService.isRunning;
    if (!shouldHandleAndroidHomeConnectionStatus(
      uiConnected: _isConnected,
      runtimeRunning: running,
    )) {
      return;
    }
    final runtimeSelectedNodeName = running && !_isConnecting
        ? await clashService.currentSelectedProxyName()
        : null;
    if (!mounted ||
        _disposed ||
        statusEpoch != _connectionStatusEpoch ||
        !identical(_registeredClashService, clashService) ||
        clashService.isRunning != running) {
      return;
    }
    final transition = transitionAndroidHomeConnectionStatus(
      running: running,
      connecting: _isConnecting,
      errorMessage: _errorMessage,
      selectedNode: _selectedNode,
      nodes: _nodes,
      runtimeSelectedNodeName: runtimeSelectedNodeName,
    );
    _updateHomeState(() {
      _isConnected = transition.connected;
      _isConnecting = transition.connecting;
      _errorMessage = transition.errorMessage;
      _selectedNode = transition.selectedNode;
      if (!running) {
        _latencyController.clear();
        _resetPublicIpState();
      }
    });
    if (running) {
      _glowController.repeat();
      _schedulePublicIpRefresh();
    } else {
      _glowController.stop();
    }
  }

  ConnectionOrchestrator get _orchestrator => ConnectionOrchestrator(
        clashService: context.read<ClashService>(),
        settingsService: context.read<SettingsService>(),
        subscriptionService: context.read<SubscriptionService>(),
      );

  void _checkUpdateDelayed() {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer(const Duration(seconds: 10), () async {
      if (!mounted ||
          !_isConnected ||
          _updateCheckInProgress ||
          UpdateService.isUpdateUiBusy) {
        return;
      }
      _updateCheckInProgress = true;
      try {
        const currentVersion = UpdateService.appVersion;
        final update = await UpdateService.checkForUpdate(currentVersion);
        if (update != null &&
            mounted &&
            _isConnected &&
            !UpdateService.isUpdateUiBusy) {
          await UpdateService.showUpdateDialog(
            context,
            latestVersion: update.version,
            currentVersion: currentVersion,
            downloadUrl: update.downloadUrl,
            changelog: update.changelog,
            sha256: update.sha256,
            fallbackDownloadUrl: update.fallbackDownloadUrl,
          );
        }
      } catch (e) {
        AppLogger.warning('Update', '检查更新异常: $e');
      } finally {
        _updateCheckInProgress = false;
      }
    });
  }
}

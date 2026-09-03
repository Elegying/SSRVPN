part of 'home_screen.dart';

extension _AndroidHomeLifecycleActions on HomeScreenState {
  void _registerClashService(ClashService clashService) {
    final previous = _registeredClashService;
    if (identical(previous, clashService)) return;
    if (previous != null) {
      if (identical(previous.onAutoConnect, _onClashAutoConnect)) {
        previous.onAutoConnect = null;
      }
      if (identical(previous.onStatusChanged, _onClashStatusChanged)) {
        previous.onStatusChanged = null;
      }
      if (identical(previous.onRuntimeNotice, _onClashRuntimeNotice)) {
        previous.onRuntimeNotice = null;
      }
    }
    _registeredClashService = clashService;
    _connectionStatusEpoch++;
    _statusApplicationEpoch++;
    _observedClashRunning = clashService.isRunning;
    _observedNativeTransitioning = clashService.nativeConnectionTransitioning;
    _observedNativeSessionGeneration = clashService.nativeSessionGeneration;
    clashService.onAutoConnect = _onClashAutoConnect;
    clashService.onStatusChanged = _onClashStatusChanged;
    clashService.onRuntimeNotice = _onClashRuntimeNotice;
  }

  bool _onSubscriptionChanged(SubscriptionService subService) {
    final controller = HomeNodeController(
      nodes: _nodes,
      lastRevision: _lastRevision,
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
      _schedulePublicIpRefresh();
      _checkUpdateDelayed();
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
    final running = clashService.isRunning;
    final nativeTransitioning = clashService.nativeConnectionTransitioning;
    final nativeSessionGeneration = clashService.nativeSessionGeneration;
    if (_observedClashRunning != running ||
        _observedNativeTransitioning != nativeTransitioning ||
        _observedNativeSessionGeneration != nativeSessionGeneration) {
      _connectionStatusEpoch++;
      _observedClashRunning = running;
      _observedNativeTransitioning = nativeTransitioning;
      _observedNativeSessionGeneration = nativeSessionGeneration;
    }
    final applicationEpoch = ++_statusApplicationEpoch;
    unawaited(
      _applyClashStatusChanged(
        clashService,
        _connectionStatusEpoch,
        applicationEpoch,
      ),
    );
  }

  void _handleClashRuntimeNotice(RuntimeNotice notice) {
    if (!mounted || _disposed) return;
    switch (notice.level) {
      case RuntimeNoticeLevel.progress:
      case RuntimeNoticeLevel.warning:
        _updateHomeState(() {
          _connectionNotice = notice.message;
          _errorMessage = null;
        });
      case RuntimeNoticeLevel.error:
        _updateHomeState(() {
          _connectionNotice = null;
          _errorMessage = notice.message;
        });
      case RuntimeNoticeLevel.success:
        return;
    }
  }

  Future<void> _applyClashStatusChanged(
    ClashService clashService,
    int statusEpoch,
    int applicationEpoch,
  ) async {
    final running = clashService.isRunning;
    final nativeTransitioning = clashService.nativeConnectionTransitioning;
    final connectionNotice = clashService.underlyingNetworkNotice;
    final shouldHandleConnection = shouldHandleAndroidHomeConnectionStatus(
      uiConnected: _isConnected,
      uiConnecting: _isConnecting,
      uiNativeRecoveryActive: _nativeRecoveryInProgress,
      runtimeRunning: running,
      runtimeTransitioning: nativeTransitioning,
    );
    if (!shouldHandleConnection) {
      if (_connectionNotice != connectionNotice) {
        _updateHomeState(() => _connectionNotice = connectionNotice);
      }
      return;
    }
    final runtimeSelectedNodeName = running && !_isConnecting
        ? await clashService.currentSelectedProxyName()
        : null;
    if (!mounted ||
        _disposed ||
        statusEpoch != _connectionStatusEpoch ||
        applicationEpoch != _statusApplicationEpoch ||
        !identical(_registeredClashService, clashService) ||
        clashService.isRunning != running ||
        clashService.nativeConnectionTransitioning != nativeTransitioning) {
      return;
    }
    final transition = transitionAndroidHomeConnectionStatus(
      running: running,
      connecting: _isConnecting,
      connectionDesired: clashService.connectionDesired,
      nativeTransitioning: nativeTransitioning,
      nativeRecoveryActive: _nativeRecoveryInProgress,
      errorMessage: _errorMessage,
      selectedNode: _selectedNode,
      nodes: _nodes,
      runtimeSelectedNodeName: runtimeSelectedNodeName,
    );
    _updateHomeState(() {
      _isConnected = transition.connected;
      _isConnecting = transition.connecting;
      _nativeRecoveryInProgress = transition.nativeRecoveryActive;
      _errorMessage = transition.errorMessage;
      _selectedNode = transition.selectedNode;
      _connectionNotice = running ? connectionNotice : null;
      if (!running) {
        _latencyController.clear();
        _resetPublicIpState();
      }
    });
    if (running) {
      _schedulePublicIpRefresh();
      _checkUpdateDelayed();
    } else {
      _updateCheckTimer?.cancel();
    }
  }

  void _checkUpdateDelayed() {
    if (!_isConnected) return;
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
        if (update != null && mounted && _isConnected) {
          context.read<UpdateAvailabilityController>().publish(update);
        }
      } catch (e) {
        AppLogger.warning('Update', '检查更新异常: $e');
      } finally {
        _updateCheckInProgress = false;
      }
    });
  }

  Future<void> _checkForUpdateManually() async {
    if (!mounted || _disposed) return;
    if (_updateCheckInProgress || UpdateService.isUpdateUiBusy) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('更新操作正在进行，请稍候')),
      );
      return;
    }

    _updateCheckTimer?.cancel();
    _updateCheckInProgress = true;
    try {
      const currentVersion = UpdateService.appVersion;
      final update = await UpdateService.checkForUpdate(currentVersion);
      if (!mounted || _disposed) return;
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
      if (mounted && !_disposed) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('检查更新失败，请检查网络后重试')),
        );
      }
    } finally {
      _updateCheckInProgress = false;
    }
  }
}

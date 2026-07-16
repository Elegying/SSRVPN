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

  void _scheduleLatencyFlush() {
    _latencyBatchTimer?.cancel();
    _latencyBatchTimer =
        Timer(const Duration(milliseconds: 100), _flushPendingLatencies);
  }

  void _flushPendingLatencies() {
    if (!_latencyController.hasPending || !mounted || _disposed) return;
    _updateHomeState(() {
      _latencyController.flushTo(_nodes);
    });
  }

  Future<void> _loadInitialData() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
    if (nodes.isNotEmpty) {
      _updateHomeState(() {
        _nodes = nodes;
        _lastRevision = subService.revision;
        if (clashService.isRunning) {
          _selectedNode = _resolveDefaultNode(
            nodes,
            settingsService.settings.lastSelectedNodeName,
          );
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_autoTestAllNodes());
      });
    }
    if (clashService.isRunning) {
      _updateHomeState(() => _isConnected = true);
      _glowController.repeat();
      _schedulePublicIpRefresh();
    }

    _registeredClashService = clashService;
    clashService.onAutoConnect = _onClashAutoConnect;

    final pendingAutoConnect = await clashService.consumePendingAutoConnect();
    if (pendingAutoConnect && !_isConnected && mounted) {
      unawaited(_handleConnectToggle());
    }

    clashService.onStatusChanged = _onClashStatusChanged;
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
    if (_isConnected == running) return;
    _updateHomeState(() {
      _isConnected = running;
      if (!running) {
        _latencyController.clear();
        _selectedNode = null;
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
        notificationService: NotificationService.instance,
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

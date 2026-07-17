part of 'home_screen.dart';

extension _AndroidHomeNodeActions on HomeScreenState {
  Future<void> _handleTestLatency(
    String nodeName,
    String server,
    int port,
  ) async {
    if (_testingNodeName == nodeName) return;
    _updateHomeState(() => _testingNodeName = nodeName);
    final clashService = context.read<ClashService>();
    final settings = context.read<SettingsService>().settings;
    final measuredLatency = await clashService.testLatency(
      server,
      port,
      timeoutMs: settings.latencyTestTimeout,
    );
    final latency = PrivateNodeLatencyPolicy.displayLatencyForNode(
      nodeName,
      measuredLatency,
      random: math.Random(),
    );
    if (mounted && !_disposed) {
      _updateHomeState(() {
        _testingNodeName = null;
        _latencyController.applyNow(_nodes, nodeName, latency);
      });
      _sortNodesByLatency();
    }
  }

  Future<void> _handleSelectNode(ProxyNode node) {
    if (!_latencyController.canSelect(node)) return Future<void>.value();
    if (!_isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
            content: Text('请先连接VPN'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return Future<void>.value();
    }
    final clashService = context.read<ClashService>();
    final generation = clashService.requestConnectionIntent(true);
    final operation = _nodeSelectionTail.then(
      (_) => _performSelectNode(node, clashService, generation),
    );
    _nodeSelectionTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning('NodeSelection', '节点切换事务失败: $error');
      },
    );
    return operation;
  }

  Future<void> _performSelectNode(
    ProxyNode node,
    ClashService clashService,
    int generation,
  ) async {
    bool isCurrent() => clashService.isConnectionIntentCurrent(
          generation,
          connected: true,
        );

    if (!isCurrent()) return;
    final result = await clashService.switchSelectedProxyForConnection(
      node.name,
      connectionGeneration: generation,
    );
    if (!result.intentCurrent || !isCurrent()) return;
    var snapshotPersisted = result.snapshotPersisted;
    if (result.liveSwitched) {
      await _rememberSelectedNode(node, shouldContinue: isCurrent);
      if (!isCurrent()) return;
      snapshotPersisted = await _writePreferredNodeConfigForTile(
            node,
            shouldContinue: isCurrent,
          ) ||
          snapshotPersisted;
      if (!isCurrent()) return;
      if (mounted && !_disposed) {
        _updateHomeState(() => _selectedNode = node);
      }
      _schedulePublicIpRefresh();
    }
    if (mounted && !_disposed && isCurrent()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text(
            !result.liveSwitched
                ? '切换失败: ${node.name}'
                : snapshotPersisted
                    ? '已切换: ${node.name}'
                    : '已切换: ${node.name}；快速启动信息保存失败',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _editNode(ProxyNode node) async {
    final success = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => NodeEditScreen(node: node)),
    );
    if (success == true && mounted) {
      _latencyController.remove(node.name);
      _loadInitialData();
    }
  }

  ProxyNode? _resolveDefaultNode(
    List<ProxyNode> nodes,
    String? rememberedNodeName,
  ) {
    return HomeNodeController.resolveDefaultNodeFrom(
      nodes,
      rememberedNodeName,
    );
  }

  Future<void> _rememberSelectedNode(
    ProxyNode node, {
    required bool Function() shouldContinue,
  }) async {
    if (!shouldContinue()) return;
    final settingsService = context.read<SettingsService>();
    if (settingsService.settings.lastSelectedNodeName == node.name) return;
    await settingsService.setLastSelectedNodeName(node.name);
  }

  Future<bool> _writePreferredNodeConfigForTile(
    ProxyNode node, {
    required bool Function() shouldContinue,
  }) async {
    if (!shouldContinue()) return false;
    final rawYaml = context.read<SubscriptionService>().rawYaml;
    if (rawYaml == null || rawYaml.trim().isEmpty) return false;
    final settingsService = context.read<SettingsService>();
    try {
      await context.read<ClashService>().writePreferredNodeConfig(
            rawYaml,
            settingsService.settings,
            node.name,
            shouldContinue: shouldContinue,
          );
      return shouldContinue();
    } catch (e) {
      AppLogger.warning('Tile', '更新默认节点配置失败: $e');
      return false;
    }
  }

  Future<void> _autoTestAllNodes() async {
    if (_nodes.isEmpty) return;
    final clashService = context.read<ClashService>();
    _updateHomeState(() => _isBatchTesting = true);
    _latencyController.clearPending();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _latencyController.queue(name, latency);
      _scheduleLatencyFlush();
    });
    _latencyBatchTimer?.cancel();
    _flushPendingLatencies();
    if (mounted && !_disposed) {
      _sortNodesByLatency();
      _updateHomeState(() => _isBatchTesting = false);
    }
  }

  Future<void> _handleTestAllLatency() async {
    if (_nodes.isEmpty) return;
    final clashService = context.read<ClashService>();
    _updateHomeState(() => _isBatchTesting = true);
    _latencyController.clearPending();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _latencyController.queue(name, latency);
      _scheduleLatencyFlush();
    });
    _latencyBatchTimer?.cancel();
    _flushPendingLatencies();
    if (mounted && !_disposed) {
      _sortNodesByLatency();
      _updateHomeState(() => _isBatchTesting = false);
    }
  }

  void _sortNodesByLatency() {
    _updateHomeState(() {
      _nodes = _latencyController.timeoutLast(_nodes);
    });
  }
}

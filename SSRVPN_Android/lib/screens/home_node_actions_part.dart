part of 'home_screen.dart';

extension _AndroidHomeNodeActions on HomeScreenState {
  Future<void> _handleTestLatency(
    String nodeName,
    String server,
    int port,
  ) async {
    if (_testingNodeName == nodeName) return;
    _cancelLatencyBatch();
    final generation = ++_singleLatencyGeneration;
    final subscriptionService = context.read<SubscriptionService>();
    final subscriptionRevision = subscriptionService.revision;
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
    if (!mounted || _disposed || generation != _singleLatencyGeneration) {
      return;
    }
    final isCurrent = isAndroidNodeLatencyResultCurrent(
      operationGeneration: generation,
      currentGeneration: _singleLatencyGeneration,
      operationSubscriptionRevision: subscriptionRevision,
      currentSubscriptionRevision: subscriptionService.revision,
      nodeName: nodeName,
      server: server,
      port: port,
      currentNodes: _nodes,
    );
    _updateHomeState(() {
      _testingNodeName = null;
      if (isCurrent) {
        _latencyController.applyNow(_nodes, nodeName, latency);
        _nodes = _latencyController.timeoutLast(_nodes);
      }
    });
  }

  Future<void> _handleSelectNode(ProxyNode node) async {
    final intent = resolveAndroidNodeSelectionIntent(
      isConnected: _isConnected,
      isConnecting: _isConnecting,
    );
    if (intent == AndroidNodeSelectionIntent.ignore) return;
    if (intent == AndroidNodeSelectionIntent.rememberForNextConnection) {
      // Keep offline selection entirely local: no ClashService lookup or live
      // proxy switch is allowed until a connection exists.
      final previousNode = _selectedNode;
      _updateHomeState(() => _selectedNode = node);
      try {
        await _rememberSelectedNode(
          node,
          shouldContinue: () => mounted && !_disposed,
        );
        if (!mounted || _disposed) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
            content: Text('已选择: ${node.name}，连接时生效'),
            duration: const Duration(seconds: 2),
          ),
        );
      } catch (error) {
        AppLogger.warning('NodeSelection', '保存首选节点失败: $error');
        if (!mounted || _disposed) return;
        _updateHomeState(() {
          _selectedNode = rollbackAndroidOfflineNodeSelection(
            previousNode: previousNode,
            attemptedNode: node,
            currentNode: _selectedNode,
          );
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
            content: Text('保存首选节点失败，请重试'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    if (!_latencyController.canSelect(node)) return;
    final clashService = context.read<ClashService>();
    final generation = clashService.requestConnectionIntent(true);
    final statusEpoch = _connectionStatusEpoch;
    final operation = _nodeSelectionTail.then(
      (_) => _performSelectNode(node, clashService, generation, statusEpoch),
    );
    _nodeSelectionTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning('NodeSelection', '节点切换事务失败: $error');
      },
    );
    try {
      await operation;
    } catch (_) {
      if (!mounted || _disposed) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text('节点切换失败，请稍后重试'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _performSelectNode(
    ProxyNode node,
    ClashService clashService,
    int generation,
    int statusEpoch,
  ) async {
    bool isCurrent() =>
        statusEpoch == _connectionStatusEpoch &&
        _isConnected &&
        clashService.isConnectionIntentCurrent(
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
    ProxyNode? reconciledRuntimeNode;
    if (result.liveSwitched) {
      snapshotPersisted = await _writePreferredNodeConfigForTile(
            node,
            shouldContinue: isCurrent,
            expectedSessionGeneration: result.nativeSessionGeneration,
          ) ||
          snapshotPersisted;
      if (!isCurrent()) return;
      if (!snapshotPersisted) {
        final runtimeNodeName = await clashService.currentSelectedProxyName();
        if (!isCurrent() || runtimeNodeName != node.name) return;
      }
      await _rememberSelectedNode(node, shouldContinue: isCurrent);
      if (!isCurrent()) return;
      if (mounted && !_disposed) {
        _updateHomeState(() => _selectedNode = node);
      }
      _schedulePublicIpRefresh();
    } else {
      reconciledRuntimeNode = resolveAndroidHomeNodeAfterFailedSwitch(
        nodes: _nodes,
        runtimeSelectedNodeName: result.runtimeNodeName,
      );
      if (reconciledRuntimeNode != null) {
        snapshotPersisted = await _writePreferredNodeConfigForTile(
          reconciledRuntimeNode,
          shouldContinue: isCurrent,
          expectedSessionGeneration: result.nativeSessionGeneration,
        );
        if (!isCurrent()) return;
        await _rememberSelectedNode(
          reconciledRuntimeNode,
          shouldContinue: isCurrent,
        );
        if (!isCurrent()) return;
        if (mounted && !_disposed) {
          _updateHomeState(() => _selectedNode = reconciledRuntimeNode);
        }
        _schedulePublicIpRefresh();
      }
    }
    if (mounted && !_disposed && isCurrent()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text(
            !result.liveSwitched
                ? reconciledRuntimeNode == null
                    ? '切换失败: ${node.name}'
                    : snapshotPersisted
                        ? '切换失败: ${node.name}；当前节点: ${reconciledRuntimeNode.name}'
                        : '切换失败: ${node.name}；当前节点: ${reconciledRuntimeNode.name}；快速启动信息保存失败'
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
    required int? expectedSessionGeneration,
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
            expectedSessionGeneration: expectedSessionGeneration,
          );
      return shouldContinue();
    } catch (e) {
      AppLogger.warning('Tile', '更新默认节点配置失败: $e');
      return false;
    }
  }

  Future<void> _autoTestAllNodes() => _runBatchLatencyTest();

  Future<void> _handleTestAllLatency() => _runBatchLatencyTest();

  Future<void> _runBatchLatencyTest() async {
    if (_nodes.isEmpty) return;
    final clashService = context.read<ClashService>();
    final subscriptionService = context.read<SubscriptionService>();
    final nodesUnderTest = List<ProxyNode>.from(_nodes);
    final subscriptionRevision = subscriptionService.revision;
    _cancelSingleLatencyTest();
    _cancelLatencyBatch();
    final generation = _latencyController.beginBatch();
    _latencyBatchGeneration = generation;
    _updateHomeState(() => _isBatchTesting = true);

    bool isCurrent() =>
        mounted &&
        !_disposed &&
        _latencyBatchGeneration == generation &&
        _latencyController.isCurrentBatch(generation) &&
        subscriptionService.revision == subscriptionRevision;

    try {
      await clashService.testAllLatencies(
        nodesUnderTest,
        (name, latency) {
          if (!_latencyController.queueForBatch(generation, name, latency)) {
            return;
          }
          _scheduleLatencyFlush(generation);
        },
        shouldContinue: isCurrent,
      );
    } catch (error) {
      AppLogger.warning('Latency', '批量延迟测试失败: $error');
    }
    _latencyBatchTimer?.cancel();
    if (!isCurrent()) {
      if (_latencyBatchGeneration == generation) _cancelLatencyBatch();
      return;
    }
    _updateHomeState(() {
      if (_latencyController.finishBatch(generation, _nodes)) {
        _nodes = _latencyController.timeoutLast(_nodes);
        _latencyBatchGeneration = null;
        _isBatchTesting = false;
      }
    });
  }
}

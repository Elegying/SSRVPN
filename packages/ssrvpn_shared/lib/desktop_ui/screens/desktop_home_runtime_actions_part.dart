part of desktop_home_screen;

extension _DesktopHomeRuntimeActions on _HomeScreenState {
  Future<void> _reloadConfig() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final rawYaml = subService.rawYaml;
    if (rawYaml == null || rawYaml.isEmpty) return;
    final subscriptionRevision = subService.revision;
    final connectionGeneration = clashService.captureAutomaticRestartIntent();
    if (connectionGeneration == null) return;

    setState(() => _isConnecting = true);
    try {
      final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
      if (nodes.isEmpty) {
        setState(() {
          _isConnected = clashService.isRunning;
          _isConnecting = false;
          _errorMessage = '订阅中没有可用节点，已保留当前连接';
        });
        return;
      }
      final preferredNode = HomeNodeController.resolveDefaultNodeFrom(
        nodes,
        settingsService.settings.lastSelectedNodeName,
      );
      ProxyNode? runtimeSelectedNode;
      clashService.interruptPendingStart();
      final connectionResult = await clashService.runConnectionTransition(
        () async {
          await clashService.stop();
          return const DesktopConnectionCoordinator().connect(
            preferredSettings: settingsService.settings,
            prepareForStart: clashService.prepareForStart,
            generateConfig: (runtimeSettings) =>
                clashService.generateClashConfigAsync(
              rawYaml,
              runtimeSettings,
              preferredNodeName: preferredNode?.name,
            ),
            writeConfig: clashService.writeConfig,
            start: clashService.start,
            stop: clashService.stop,
            isRevisionCurrent: () =>
                subService.revision == subscriptionRevision,
            isIntentCurrent: () => clashService.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            ),
            shouldRollbackStaleIntent: () => !clashService.connectionDesired,
            cancelIntent: () {
              clashService.requestConnectionIntent(false);
              clashService.interruptPendingStart();
            },
            readStartFailureReason: () => clashService.lastStartError,
            readRuntimeNotice: () =>
                clashService.lastRuntimePortAdjustmentMessage,
            switchPreferredNode: (isConnectionContextCurrent) async {
              final switchStatusEpoch = _connectionStatusEpoch;
              var switched = true;
              if (preferredNode != null) {
                switched = await clashService.switchSelectedProxy(
                  preferredNode.name,
                  isSwitchContextCurrent: () =>
                      _canUpdateUi &&
                      switchStatusEpoch == _connectionStatusEpoch &&
                      clashService.isRunning &&
                      isConnectionContextCurrent(),
                );
              }
              runtimeSelectedNode = await _resolveRuntimeSelectedNode(
                clashService,
                nodes,
              );
              return switched;
            },
          );
        },
      );
      if (connectionResult.failure == DesktopConnectionFailure.cancelled) {
        return;
      }
      if (connectionResult.failure ==
          DesktopConnectionFailure.subscriptionChanged) {
        throw StateError(
          connectionResult.failureReason ?? desktopSubscriptionChangedMessage,
        );
      }
      var success = connectionResult.connected &&
          clashService.isRunning &&
          subService.revision == subscriptionRevision &&
          clashService.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          );
      if (success &&
          preferredNode != null &&
          connectionResult.preferredNodeSwitchSucceeded == true &&
          runtimeSelectedNode?.name == preferredNode.name) {
        await _rememberSelectedNode(preferredNode);
        success = clashService.isRunning &&
            subService.revision == subscriptionRevision &&
            clashService.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            );
      }
      if (success) {
        clashService.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: settingsService.settings,
          generateConfig: (runtimeSettings, preferredNodeName) =>
              clashService.generateClashConfigAsync(
            rawYaml,
            runtimeSettings,
            preferredNodeName: preferredNodeName,
          ),
          isRevisionCurrent: () => subService.revision == subscriptionRevision,
          preferredNodeName: runtimeSelectedNode?.name ?? preferredNode?.name,
        );
      }
      if (_canUpdateUi) {
        if (!success) {
          clashService.requestConnectionIntent(false);
          clashService.interruptPendingStart();
        }
        setState(() {
          _isConnected = success;
          _isConnecting = false;
          _errorMessage = null;
          _nodes = nodes;
          _selectedNode = success ? runtimeSelectedNode : null;
          if (!success) _resetPublicIpState();
        });
        if (success) {
          final nodeWarning = connectionResult.preferredNodeSwitchWarning(
            preferredNodeName: preferredNode?.name,
            runtimeNodeName: runtimeSelectedNode?.name,
          );
          final notice = nodeWarning ?? connectionResult.runtimeNotice;
          _showRuntimePortAdjustmentNotice(notice);
          _scheduleExitCountryResolution();
          _schedulePublicIpRefresh();
        }
      }
      if (!success) return;
    } catch (e) {
      AppLogger.warning('Connection', '重载配置失败: $e');
      final isCurrent = clashService.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      );
      if (!isCurrent && clashService.connectionDesired) return;
      final stillRunning = clashService.isRunning;
      if (!stillRunning && isCurrent) {
        clashService.requestConnectionIntent(false);
        clashService.interruptPendingStart();
      }
      if (_canUpdateUi) {
        setState(() {
          _isConnected = stillRunning;
          _isConnecting = false;
          _errorMessage = stillRunning
              ? '网络设置未能应用，当前连接仍保留。请重试；持续失败请重新连接并运行诊断。'
              : '网络设置重载失败，连接已停止。请重新连接；持续失败请运行诊断。';
          if (!stillRunning) _resetPublicIpState();
        });
      }
    }
  }

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
    setState(() => _testingNodeName = nodeName);
    final clashService = context.read<ClashService>();
    final settings = context.read<SettingsService>().settings;
    final nodeUnderTest = _nodes
        .where(
          (node) =>
              node.name == nodeName &&
              node.server == server &&
              node.port == port,
        )
        .firstOrNull;
    final measuredLatency = nodeUnderTest == null
        ? -1
        : await clashService.testNodeLatency(
            nodeUnderTest,
            timeoutMs: settings.latencyTestTimeout,
          );
    final latency = PrivateNodeLatencyPolicy.displayLatencyForNode(
      nodeName,
      measuredLatency,
      random: math.Random(),
    );
    final isCurrent = _canUpdateUi &&
        generation == _singleLatencyGeneration &&
        subscriptionService.revision == subscriptionRevision &&
        _nodes.any(
          (node) =>
              node.name == nodeName &&
              node.server == server &&
              node.port == port,
        );
    if (isCurrent) {
      setState(() {
        _testingNodeName = null;
        _latencyController.applyNow(_nodes, nodeName, latency);
      });
      _sortNodesByLatency();
    } else if (_canUpdateUi &&
        generation == _singleLatencyGeneration &&
        _testingNodeName == nodeName) {
      setState(() => _testingNodeName = null);
    }
  }

  Future<void> _handleSelectNode(ProxyNode node) async {
    if (!_canUpdateUi || _isConnecting) return;
    if (!_isConnected) {
      setState(() => _disconnectedPreferredNodeName = node.name);
      final saved = await _rememberSelectedNode(node);
      if (!_canUpdateUi) return;
      if (!saved && _disconnectedPreferredNodeName == node.name) {
        setState(() => _disconnectedPreferredNodeName = null);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved ? '已选择: ${node.name}，连接时生效' : '保存首选节点失败，请重试',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!_latencyController.canSelect(node)) return;
    final core = context.read<ClashService>();
    final generation = core.captureAutomaticRestartIntent();
    var cleanupAuthorized = false;

    bool owns() =>
        _canUpdateUi &&
        _isConnected &&
        !_isConnecting &&
        core.isRunning &&
        identical(_clashService, core) &&
        generation != null &&
        core.isConnectionIntentCurrent(generation, connected: true);

    if (!owns()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('切换失败: ${node.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }
    _exitCountryResolveGeneration++;
    final ok = await core.switchSelectedProxy(
      node.name,
      isSwitchContextCurrent: () => cleanupAuthorized = owns(),
    );
    if (!owns() || (ok && !cleanupAuthorized)) {
      return;
    }
    var nodePersisted = true;
    if (ok) {
      nodePersisted = await _rememberSelectedNode(node);
      if (!owns()) return;
      setState(() => _selectedNode = node);
      _scheduleExitCountryResolution();
      _schedulePublicIpRefresh();
    }
    if (!owns()) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          !ok
              ? '切换失败: ${node.name}'
              : nodePersisted
                  ? '已切换: ${node.name}'
                  : '已切换，但首选节点保存失败: ${node.name}',
        ),
        duration: Duration(seconds: ok && !nodePersisted ? 3 : 1),
      ),
    );
  }

  Future<void> _showNodeContextMenu(
    ProxyNode node,
    TapDownDetails details,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18),
              SizedBox(width: 10),
              Text('编辑'),
            ],
          ),
        ),
      ],
    );
    if (selected != 'edit' || !mounted) return;
    await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => NodeEditScreen(node: node)));
  }

  Future<ProxyNode?> _resolveRuntimeSelectedNode(
    ClashService clashService,
    List<ProxyNode> nodes,
  ) async {
    final runtimeNodeName = await clashService.currentSelectedProxyName();
    return HomeNodeController.resolveRuntimeSelectedNodeFrom(
      nodes,
      runtimeNodeName,
    );
  }

  Future<void> _runBatchLatencyTest() async {
    if (_nodes.isEmpty) return;
    final clashService = context.read<ClashService>();
    final subscriptionService = context.read<SubscriptionService>();
    final timeout = context.read<SettingsService>().settings.latencyTestTimeout;
    final nodesUnderTest = List<ProxyNode>.from(_nodes);
    final subscriptionRevision = subscriptionService.revision;
    _cancelLatencyBatch();
    final generation = _latencyController.beginBatch();
    _latencyBatchGeneration = generation;
    setState(() => _isBatchTesting = true);

    bool isCurrent() =>
        _canUpdateUi &&
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
        timeoutMs: timeout,
        shouldContinue: isCurrent,
      );
    } catch (error) {
      AppLogger.warning('Latency', '批量延迟测试失败: $error');
    }
    _latencyBatchTimer?.cancel();
    if (!isCurrent()) {
      if (_canUpdateUi && _latencyBatchGeneration == generation) {
        setState(_cancelLatencyBatch);
      } else if (_latencyBatchGeneration == generation) {
        _cancelLatencyBatch();
      }
      return;
    }
    setState(() {
      if (_latencyController.finishBatch(generation, _nodes)) {
        _nodes = _latencyController.timeoutLast(_nodes);
        _latencyBatchGeneration = null;
        _isBatchTesting = false;
      }
    });
  }

  void _sortNodesByLatency() {
    setState(() {
      _nodes = _latencyController.timeoutLast(_nodes);
    });
  }

  void _scheduleExitCountryResolution() {
    if (!_isConnected || _nodes.isEmpty || !_canUpdateUi) return;
    if (_isResolvingExitCountries) {
      _pendingExitCountryResolution = true;
      return;
    }
    unawaited(_resolveExitCountries());
  }

  Future<void> _resolveExitCountries() async {
    if (_isResolvingExitCountries) return;
    _isResolvingExitCountries = true;
    _pendingExitCountryResolution = false;
    final generation = ++_exitCountryResolveGeneration;

    bool shouldContinue() {
      return _canUpdateUi && generation == _exitCountryResolveGeneration;
    }

    try {
      final resolved = HomeExitCountryController.resolveMissingCountries(
        List<ProxyNode>.from(_nodes),
        _exitCountryCodes,
      );
      if (resolved.isNotEmpty && shouldContinue()) {
        setState(() {
          _exitCountryCodes.addAll(resolved);
        });
      }
    } catch (e) {
      AppLogger.warning('ExitCountry', '查询失败: $e');
    } finally {
      _isResolvingExitCountries = false;

      if (_pendingExitCountryResolution && _canUpdateUi) {
        _pendingExitCountryResolution = false;
        _scheduleExitCountryResolution();
      }
    }
  }
}

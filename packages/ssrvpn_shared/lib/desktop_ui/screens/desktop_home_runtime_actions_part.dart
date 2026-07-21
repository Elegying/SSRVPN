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
      final preferredNode = _resolveDefaultNode(
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
            switchPreferredNode: () async {
              if (preferredNode != null) {
                final switched = await clashService.switchSelectedProxy(
                  preferredNode.name,
                );
                runtimeSelectedNode = await _resolveRuntimeSelectedNode(
                  clashService,
                  nodes,
                );
                return switched;
              }
              runtimeSelectedNode = await _resolveRuntimeSelectedNode(
                clashService,
                nodes,
              );
              return true;
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
      if (mounted && !_disposed) {
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
          _showRuntimePortAdjustmentNotice(connectionResult.runtimeNotice);
          _scheduleExitCountryResolution();
          _schedulePublicIpRefresh();
        }
      }
      if (!success) return;

      // TUN data-plane checks are owned by ClashService so reload cannot
      // promote an advisory warning into a desktop connection error.
      if (!clashService.settings.enableTun) {
        final connectivityWarning = await clashService.verifyUserConnectivity(
          shouldContinue: () => clashService.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          ),
        );
        if (mounted &&
            !_disposed &&
            clashService.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            )) {
          setState(() => _errorMessage = connectivityWarning);
        }
      }
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
      if (mounted && !_disposed) {
        final msg = e
            .toString()
            .replaceFirst('Exception: ', '')
            .replaceFirst('Bad state: ', '');
        setState(() {
          _isConnected = stillRunning;
          _isConnecting = false;
          _errorMessage =
              stillRunning ? '连接重载失败，已保留当前连接: $msg' : '连接重载失败: $msg';
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
    final isCurrent = mounted &&
        !_disposed &&
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
    } else if (mounted &&
        !_disposed &&
        generation == _singleLatencyGeneration &&
        _testingNodeName == nodeName) {
      setState(() => _testingNodeName = null);
    }
  }

  Future<void> _handleSelectNode(ProxyNode node) async {
    if (!mounted || _disposed || _isConnecting) return;
    if (!_isConnected) {
      setState(() => _disconnectedPreferredNodeName = node.name);
      final saved = await _rememberSelectedNode(node);
      if (!mounted || _disposed) return;
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
    final clashService = context.read<ClashService>();
    final statusEpoch = _connectionStatusEpoch;
    final connectionGeneration = clashService.captureAutomaticRestartIntent();
    if (connectionGeneration == null) return;

    bool isCurrent() =>
        mounted &&
        !_disposed &&
        _isConnected &&
        !_isConnecting &&
        clashService.isRunning &&
        identical(_clashService, clashService) &&
        statusEpoch == _connectionStatusEpoch &&
        clashService.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        );

    if (!isCurrent()) return;
    _exitCountryResolveGeneration++;
    final ok = await clashService.switchSelectedProxy(node.name);
    if (!isCurrent()) return;
    if (ok) {
      if (!isCurrent()) return;
      await _rememberSelectedNode(node);
      if (!isCurrent()) return;
      setState(() => _selectedNode = node);
      if (!isCurrent()) return;
      _scheduleExitCountryResolution();
      if (!isCurrent()) return;
      _schedulePublicIpRefresh();
    }
    if (!isCurrent()) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已切换: ${node.name}' : '切换失败: ${node.name}'),
        duration: const Duration(seconds: 1),
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

  ProxyNode? _resolveDefaultNode(
    List<ProxyNode> nodes,
    String? rememberedNodeName,
  ) {
    return HomeNodeController.resolveDefaultNodeFrom(nodes, rememberedNodeName);
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

  Future<void> _autoTestAllNodes() => _runBatchLatencyTest();

  Future<void> _handleTestAllLatency() => _runBatchLatencyTest();

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
        timeoutMs: timeout,
        shouldContinue: isCurrent,
      );
    } catch (error) {
      AppLogger.warning('Latency', '批量延迟测试失败: $error');
    }
    _latencyBatchTimer?.cancel();
    if (!isCurrent()) {
      if (mounted && !_disposed && _latencyBatchGeneration == generation) {
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
    if (!_isConnected || _nodes.isEmpty || !mounted || _disposed) return;
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
      return mounted &&
          !_disposed &&
          generation == _exitCountryResolveGeneration;
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

      if (_pendingExitCountryResolution && mounted && !_disposed) {
        _pendingExitCountryResolution = false;
        _scheduleExitCountryResolution();
      }
    }
  }
}

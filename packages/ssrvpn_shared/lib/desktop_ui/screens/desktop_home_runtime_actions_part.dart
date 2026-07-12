part of desktop_home_screen;

extension _DesktopHomeRuntimeActions on _HomeScreenState {
  Future<void> _reloadConfig() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final rawYaml = subService.rawYaml;
    if (rawYaml == null || rawYaml.isEmpty) return;
    final connectionGeneration = clashService.captureAutomaticRestartIntent();
    if (connectionGeneration == null) return;

    setState(() => _isConnecting = true);
    try {
      final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
      if (nodes.isEmpty) throw Exception('未获取到可用节点');
      final preferredNode = _resolveDefaultNode(
        nodes,
        settingsService.settings.lastSelectedNodeName,
      );
      await clashService.stop();
      if (!clashService.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        if (mounted && !_disposed) {
          setState(() {
            _isConnected = false;
            _isConnecting = false;
            _selectedNode = null;
            _resetPublicIpState();
          });
        }
        return;
      }
      final runtimeSettings = await clashService.prepareForStart(
        settingsService.settings,
      );
      final config = clashService.generateClashConfig(
        rawYaml,
        runtimeSettings,
        preferredNodeName: preferredNode?.name,
      );
      await clashService.writeConfig(config);
      if (!clashService.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        if (mounted && !_disposed) {
          setState(() {
            _isConnected = false;
            _isConnecting = false;
            _selectedNode = null;
            _resetPublicIpState();
          });
        }
        return;
      }
      final success = await clashService.start();
      if (!clashService.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        if (success) await clashService.stop();
        if (mounted && !_disposed) {
          setState(() {
            _isConnected = false;
            _isConnecting = false;
            _selectedNode = null;
            _resetPublicIpState();
          });
        }
        return;
      }
      ProxyNode? runtimeSelectedNode;
      if (success && preferredNode != null) {
        final switched = await clashService.switchSelectedProxy(
          preferredNode.name,
        );
        runtimeSelectedNode = await _resolveRuntimeSelectedNode(
          clashService,
          nodes,
        );
        if (switched && runtimeSelectedNode?.name == preferredNode.name) {
          await _rememberSelectedNode(preferredNode);
        }
      } else if (success) {
        runtimeSelectedNode = await _resolveRuntimeSelectedNode(
          clashService,
          nodes,
        );
      }
      final connectivityWarning =
          success ? await clashService.verifyUserConnectivity() : null;
      if (mounted && !_disposed) {
        setState(() {
          _isConnected = success;
          _isConnecting = false;
          _errorMessage = connectivityWarning;
          _nodes = nodes;
          _selectedNode = success ? runtimeSelectedNode : null;
          if (!success) _resetPublicIpState();
        });
        if (success) {
          _scheduleExitCountryResolution();
          _schedulePublicIpRefresh();
        }
      }
    } catch (e) {
      AppLogger.warning('Connection', '重载配置失败: $e');
      if (clashService.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        clashService.requestConnectionIntent(false);
      }
      if (mounted && !_disposed) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _errorMessage = '连接重载失败: $msg';
          _resetPublicIpState();
        });
      }
    }
  }

  void _checkUpdateDelayed() {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer(const Duration(seconds: 10), () async {
      if (!mounted || !_isConnected) return;
      try {
        const currentVersion = UpdateService.appVersion;
        final update = await UpdateService.checkForUpdate(currentVersion);
        if (update != null && mounted && _isConnected) {
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
      }
    });
  }

  void _schedulePublicIpRefresh() {
    _publicIpTimer?.cancel();
    if (!_isConnected || _isConnecting || !mounted || _disposed) return;
    final generation = ++_publicIpGeneration;
    _publicIpTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_refreshPublicIpInfo(generation: generation));
    });
  }

  Future<void> _refreshPublicIpInfo({int? generation}) async {
    if (!_isConnected || _isConnecting || !mounted || _disposed) return;
    final effectiveGeneration = generation ?? ++_publicIpGeneration;
    _publicIpTimer?.cancel();
    setState(() {
      _isRefreshingPublicIp = true;
      _publicIpError = null;
    });

    try {
      final info =
          await context.read<ClashService>().fetchCurrentPublicIpInfo();
      if (!mounted || _disposed || effectiveGeneration != _publicIpGeneration) {
        return;
      }
      setState(() {
        _publicIpInfo = info;
        _publicIpError = null;
        _isRefreshingPublicIp = false;
      });
    } catch (e) {
      AppLogger.warning('PublicIP', '获取公网 IP 失败: $e');
      if (!mounted || _disposed || effectiveGeneration != _publicIpGeneration) {
        return;
      }
      setState(() {
        _publicIpError = '获取失败';
        _isRefreshingPublicIp = false;
      });
    }
  }

  void _resetPublicIpState() {
    _publicIpTimer?.cancel();
    _publicIpGeneration++;
    _publicIpInfo = null;
    _isRefreshingPublicIp = false;
    _publicIpError = null;
  }

  Future<void> _handleTestLatency(
    String nodeName,
    String server,
    int port,
  ) async {
    if (_testingNodeName == nodeName) return;
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
    if (mounted && !_disposed) {
      setState(() {
        _testingNodeName = null;
        _latencyController.applyNow(_nodes, nodeName, latency);
      });
      _sortNodesByLatency();
    }
  }

  Future<void> _handleSelectNode(ProxyNode node) async {
    if (!_latencyController.canSelect(node)) return;
    if (!_isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请先连接VPN'),
            duration: Duration(seconds: 1),
          ),
        );
      }
      return;
    }
    _exitCountryResolveGeneration++;
    final ok = await context.read<ClashService>().switchSelectedProxy(
          node.name,
        );
    if (ok) {
      await _rememberSelectedNode(node);
      if (mounted) setState(() => _selectedNode = node);
      _scheduleExitCountryResolution();
      _schedulePublicIpRefresh();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '已切换: ${node.name}' : '切换失败: ${node.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
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

  Future<void> _syncSelectedNodeFromRuntime() async {
    final clashService = _clashService;
    if (clashService == null || !mounted || _disposed || !_isConnected) return;
    final runtimeSelectedNode = await _resolveRuntimeSelectedNode(
      clashService,
      _nodes,
    );
    if (!mounted || _disposed || !_isConnected) return;
    setState(() => _selectedNode = runtimeSelectedNode);
  }

  Future<void> _rememberSelectedNode(ProxyNode node) async {
    final settingsService = context.read<SettingsService>();
    if (settingsService.settings.lastSelectedNodeName == node.name) return;
    await settingsService.updateLastSelectedNodeName(node.name);
  }

  Future<void> _autoTestAllNodes() => _runBatchLatencyTest();

  Future<void> _handleTestAllLatency() => _runBatchLatencyTest();

  Future<void> _runBatchLatencyTest() async {
    if (_nodes.isEmpty) return;
    final clashService = context.read<ClashService>();
    final timeout = context.read<SettingsService>().settings.latencyTestTimeout;
    setState(() => _isBatchTesting = true);
    _latencyController.clearPending();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _latencyController.queue(name, latency);
      _scheduleLatencyFlush();
    }, timeoutMs: timeout);
    _latencyBatchTimer?.cancel();
    _flushPendingLatencies();
    if (mounted && !_disposed) {
      _sortNodesByLatency();
      setState(() => _isBatchTesting = false);
    }
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

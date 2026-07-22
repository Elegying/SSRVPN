part of desktop_home_screen;

bool _initialSubscriptionDialogInFlight = false;
int _lastEmptySubscriptionPromptRevision = -1;

/// 主屏幕 — 桌面优化
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ProxyNode> _nodes = [];
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isBatchTesting = false;
  String? _errorMessage;
  String? _connectivityWarning;
  String? _testingNodeName;
  ProxyNode? _selectedNode;
  PublicIpInfo? _publicIpInfo;
  bool _isRefreshingPublicIp = false;
  String? _publicIpError;

  final HomeLatencyController _latencyController = HomeLatencyController();
  final ValueNotifier<int> _nodeSelectionRefresh = ValueNotifier<int>(0);
  final Map<String, String> _exitCountryCodes = {};
  Timer? _latencyBatchTimer;
  int? _latencyBatchGeneration;
  int _singleLatencyGeneration = 0;
  String? _disconnectedPreferredNodeName;
  Timer? _publicIpTimer;
  int _lastRevision = -1;
  int _publicIpGeneration = 0;
  int _connectionStatusEpoch = 0;
  bool _disposed = false;
  bool _isResolvingExitCountries = false;
  bool _pendingExitCountryResolution = false;
  int _exitCountryResolveGeneration = 0;
  ClashService? _clashService;
  late final VoidCallback _clashStatusListener = _handleClashStatusChanged;
  SubscriptionService? _subscriptionService;
  Timer? _updateCheckTimer;
  bool _updateCheckInProgress = false;
  bool _updateCheckCompleted = false;
  int _updateCheckAttempts = 0;

  bool _isConnectionTransitionActive(ClashService clashService) =>
      _isConnecting ||
      (!clashService.isRunning && clashService.connectionDesired);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _nodeSelectionRefresh.value++;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      unawaited(_loadInitialData());
      _checkUpdateDelayed();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final subService = context.read<SubscriptionService>();
    if (identical(_subscriptionService, subService)) return;
    if (_subscriptionService != null) {
      (_clashService ?? context.read<ClashService>())
          .clearDesktopConnectionRecoveryPlan();
    }
    _subscriptionService?.removeListener(_handleSubscriptionServiceChanged);
    _subscriptionService = subService;
    subService.addListener(_handleSubscriptionServiceChanged);
    _onSubscriptionChanged(subService);
  }

  void _handleSubscriptionServiceChanged() {
    final subService = _subscriptionService;
    if (subService == null || !mounted || _disposed) return;
    if (_onSubscriptionChanged(subService)) {
      setState(() {});
    }
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
    _cancelLatencyBatch();
    if (_isConnecting) {
      (_clashService ?? context.read<ClashService>()).interruptPendingStart();
    }
    _lastRevision = controller.lastRevision;
    _nodes = controller.nodes;
    if (_disconnectedPreferredNodeName != null &&
        !_nodes.any((node) => node.name == _disconnectedPreferredNodeName)) {
      _disconnectedPreferredNodeName = null;
    }
    final nodeNames = _nodes.map((node) => node.name).toSet();
    _exitCountryCodes.removeWhere((name, _) => !nodeNames.contains(name));
    if (sync.shouldPromptForImport) {
      _maybeShowInitialSubscriptionDialog(subService);
      return true;
    }
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

  @override
  void dispose() {
    _disposed = true;
    _cancelLatencyBatch();
    _publicIpTimer?.cancel();
    _updateCheckTimer?.cancel();
    _clashService?.removeStatusListener(_clashStatusListener);
    _subscriptionService?.removeListener(_handleSubscriptionServiceChanged);
    _nodeSelectionRefresh.dispose();
    super.dispose();
  }

  void _maybeShowInitialSubscriptionDialog(SubscriptionService subService) {
    final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
    if (_initialSubscriptionDialogInFlight || nodes.isNotEmpty) {
      return;
    }
    if (_lastEmptySubscriptionPromptRevision == subService.revision) return;
    _lastEmptySubscriptionPromptRevision = subService.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) unawaited(_showInitialSubscriptionDialog());
    });
  }

  String? _validateSubscriptionInput(
    String input,
    SubscriptionService subService,
  ) {
    if (input.isEmpty) return '请粘贴你的SSR代码或订阅链接';
    if (subService.isSingleNodeLink(input)) return null;

    try {
      SubscriptionUrlPolicy.parse(input);
    } on FormatException {
      return '请输入有效的 SSR 代码或 HTTP/HTTPS 订阅链接';
    }
    return null;
  }

  Future<void> _applyNetworkSetting(
    Future<void> Function(SettingsService settings) update,
  ) async {
    if (_isConnecting) return;
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final wasConnected = clashService.isRunning || _isConnected;
    int? automaticReconnectGeneration;
    var transactionCommitted = false;
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      if (wasConnected) {
        automaticReconnectGeneration =
            clashService.requestConnectionIntent(false);
        clashService.interruptPendingStart();
      }

      await clashService.runConnectionTransition(() async {
        if (wasConnected) await clashService.stop();
        await update(settingsService);
        clashService.updateSettings(settingsService.settings);
      });
      transactionCommitted = true;
      if (wasConnected) _resetPublicIpState();

      if (!mounted || _disposed) return;
      setState(() {
        _isConnected = false;
        _selectedNode = null;
        _latencyController.clear();
        _resetPublicIpState();
      });
    } catch (error, stack) {
      recordDesktopConnectionFailure(
        '更新网络设置失败',
        error: error,
        stack: stack,
      );
      if (mounted && !_disposed) {
        setState(() {
          _isConnected = clashService.isRunning;
          _errorMessage = '更新网络设置失败，请重试';
        });
      }
    } finally {
      if (mounted && !_disposed) {
        setState(() => _isConnecting = false);
      }
    }

    final reconnectGeneration = automaticReconnectGeneration;
    if (transactionCommitted &&
        reconnectGeneration != null &&
        mounted &&
        !_disposed &&
        clashService.isConnectionIntentCurrent(
          reconnectGeneration,
          connected: false,
        )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('网络设置已更新，正在重新连接')),
      );
      await _handleConnectToggle();
    }
  }

  Future<void> _showForceProxySitesDialog() async {
    final settings = context.read<SettingsService>().settings;
    final savedSites = AppSettings.normalizeForceProxySites(
      settings.forceProxySites,
    );
    final sites = await _DesktopForceProxySitesDialog.show(
      context,
      savedSites: savedSites,
    );
    if (sites == null || !mounted || _disposed) return;
    await _applyForceProxySites(sites);
  }

  Future<void> _applyForceProxySites(List<String> sites) async {
    final settingsService = context.read<SettingsService>();
    final clashService = context.read<ClashService>();
    await settingsService.updateForceProxySites(sites);
    clashService.updateSettings(settingsService.settings);

    final shouldReload = _isConnected && !_isConnecting;
    var reloadSucceeded = false;
    if (shouldReload) {
      await _reloadConfig();
      reloadSucceeded = mounted &&
          !_disposed &&
          _isConnected &&
          context.read<ClashService>().isRunning;
    }
    if (!mounted || _disposed) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          shouldReload
              ? reloadSucceeded
                  ? '强制代理网站已实时生效'
                  : '强制代理网站已保存，当前连接重载失败，请重新连接'
              : '强制代理网站已保存',
        ),
        backgroundColor:
            shouldReload && !reloadSucceeded ? AppTheme.warning : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _handleConnectToggle() async {
    final clashService = context.read<ClashService>();
    final subService = context.read<SubscriptionService>();
    final settingsService = context.read<SettingsService>();

    if (_isConnectionTransitionActive(clashService)) {
      clashService.requestConnectionIntent(false);
      clashService.interruptPendingStart();
      try {
        await clashService.runConnectionTransition(clashService.stop);
      } catch (error, stack) {
        recordDesktopConnectionFailure(
          '取消连接失败',
          error: error,
          stack: stack,
        );
        if (mounted && !_disposed) {
          setState(() {
            _errorMessage =
                '取消连接失败：${error.toString().replaceFirst('StateError: ', '')}';
          });
        }
      } finally {
        if (mounted && !_disposed) {
          setState(() {
            _isConnected = clashService.isRunning;
            _isConnecting = false;
            if (!_isConnected) {
              _selectedNode = null;
              _resetPublicIpState();
            }
          });
        }
      }
      return;
    }

    if (_isConnected) {
      clashService.requestConnectionIntent(false);
      clashService.interruptPendingStart();
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      try {
        await clashService.runConnectionTransition(clashService.stop);
        if (!mounted || _disposed) return;
        setState(() {
          _isConnected = false;
          _latencyController.clear();
          _exitCountryResolveGeneration++;
          _resetPublicIpState();
        });
      } catch (error, stack) {
        recordDesktopConnectionFailure(
          '断开连接失败',
          error: error,
          stack: stack,
        );
        if (mounted && !_disposed) {
          setState(() {
            _isConnected = clashService.isRunning;
            _errorMessage =
                '断开连接失败：${error.toString().replaceFirst('StateError: ', '')}。'
                '请再次点击连接按钮重试恢复系统代理';
          });
        }
      } finally {
        if (mounted && !_disposed) {
          setState(() => _isConnecting = false);
        }
      }
    } else {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      final connectionGeneration = clashService.requestConnectionIntent(true);
      final requestedGeneration = connectionGeneration;
      try {
        if (clashService.hasPendingSystemProxyRecovery) {
          final recovered = await clashService.recoverPendingSystemProxy();
          if (!mounted || _disposed) return;
          if (!clashService.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          )) {
            return;
          }
          if (!recovered) {
            clashService.requestConnectionIntent(false);
            clashService.interruptPendingStart();
            final reason = clashService.lastStartError ?? '系统代理旧状态恢复失败';
            recordDesktopConnectionFailure(
              'System proxy recovery failed: $reason',
            );
            setState(() {
              _isConnecting = false;
              _errorMessage = '连接失败: $reason';
              _resetPublicIpState();
            });
            return;
          }
        }
        final rawYaml = subService.rawYaml;
        if (rawYaml == null || rawYaml.isEmpty) {
          clashService.requestConnectionIntent(false);
          clashService.interruptPendingStart();
          setState(() {
            _errorMessage = '请先添加并刷新订阅';
            _isConnecting = false;
            _resetPublicIpState();
          });
          return;
        }
        final subscriptionRevision = subService.revision;

        final nodes = HomeNodeController.runnableNodesFrom(
          subService.allNodes,
        );
        if (nodes.isEmpty) {
          clashService.requestConnectionIntent(false);
          clashService.interruptPendingStart();
          setState(() {
            _errorMessage = '订阅中没有可用节点，请刷新订阅';
            _isConnecting = false;
            _resetPublicIpState();
          });
          return;
        }
        final autoSelect = _resolveDefaultNode(
          nodes,
          _disconnectedPreferredNodeName ??
              settingsService.settings.lastSelectedNodeName,
        );
        ProxyNode? runtimeSelectedNode;
        final connectionResult = await clashService.runConnectionTransition(
          () => const DesktopConnectionCoordinator().connect(
            preferredSettings: settingsService.settings,
            prepareForStart: clashService.prepareForStart,
            generateConfig: (runtimeSettings) =>
                clashService.generateClashConfigAsync(
              rawYaml,
              runtimeSettings,
              preferredNodeName: autoSelect?.name,
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
              if (autoSelect != null) {
                final switched = await clashService.switchSelectedProxy(
                  autoSelect.name,
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
          ),
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
        if (!connectionResult.connected) {
          final reason = connectionResult.failureReason ?? '无法启动核心';
          recordDesktopConnectionFailure(
            'Connection failed: $reason',
            expected: AppFailure.fromMessage(reason).code ==
                AppErrorCode.permissionRequired,
          );
          if (!mounted || _disposed) return;
          setState(() {
            _isConnected = false;
            _isConnecting = false;
            _errorMessage = '连接失败: $reason';
            _resetPublicIpState();
          });
          return;
        }
        if (autoSelect != null &&
            connectionResult.preferredNodeSwitchSucceeded == true &&
            runtimeSelectedNode?.name == autoSelect.name &&
            clashService.isRunning &&
            subService.revision == subscriptionRevision &&
            clashService.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            )) {
          await _rememberSelectedNode(autoSelect);
        }
        if (!mounted || _disposed) return;
        if (!clashService.isRunning ||
            !clashService.isConnectionIntentCurrent(
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
        clashService.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: settingsService.settings,
          generateConfig: (runtimeSettings, preferredNodeName) =>
              clashService.generateClashConfigAsync(
            rawYaml,
            runtimeSettings,
            preferredNodeName: preferredNodeName,
          ),
          isRevisionCurrent: () =>
              subService.revision == subscriptionRevision &&
              subService.rawYaml == rawYaml,
          preferredNodeName: runtimeSelectedNode?.name ?? autoSelect?.name,
        );
        setState(() {
          _isConnected = true;
          _isConnecting = false;
          _errorMessage = null;
          _nodes = nodes;
          _selectedNode = runtimeSelectedNode;
          _disconnectedPreferredNodeName = null;
        });
        _showRuntimePortAdjustmentNotice(connectionResult.runtimeNotice);
        _scheduleExitCountryResolution();
        _schedulePublicIpRefresh();
        unawaited(_autoTestAllNodes());
        _checkUpdateDelayed();

        // TUN data-plane observations belong to the service lifecycle. The
        // desktop layer must not duplicate them or turn an advisory warning
        // into a connection error after startup.
        if (!clashService.settings.enableTun) {
          final connectivityWarning = await clashService.verifyUserConnectivity(
            shouldContinue: () => clashService.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            ),
          );
          if (!mounted ||
              _disposed ||
              !clashService.isRunning ||
              !clashService.isConnectionIntentCurrent(
                connectionGeneration,
                connected: true,
              )) {
            return;
          }
          setState(() => _errorMessage = connectivityWarning);
        }
      } catch (e, stack) {
        final isCurrent = clashService.isConnectionIntentCurrent(
          requestedGeneration,
          connected: true,
        );
        if (!isCurrent && clashService.connectionDesired) return;
        if (isCurrent) {
          clashService.requestConnectionIntent(false);
          clashService.interruptPendingStart();
        }
        recordDesktopConnectionFailure(
          'Connection failed',
          error: e,
          stack: stack,
        );
        if (!mounted) return;
        final msg = e
            .toString()
            .replaceFirst('Exception: ', '')
            .replaceFirst('Bad state: ', '');
        setState(() {
          _errorMessage = '连接失败: $msg';
          _isConnecting = false;
          _resetPublicIpState();
        });
      }
    }
  }

  void _showRuntimePortAdjustmentNotice(String? message) {
    if (message == null || message.isEmpty || !mounted || _disposed) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.warning,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>().settings;
    final clashService = _clashService ?? context.read<ClashService>();
    final isConnectionTransition = _isConnectionTransitionActive(clashService);
    final displayNode = _isConnected
        ? HomeNodeController.resolveRuntimeSelectedNodeFrom(
            _nodes,
            _selectedNode?.name,
          )
        : HomeNodeController.resolveDefaultNodeFrom(
            _nodes,
            _disconnectedPreferredNodeName ?? settings.lastSelectedNodeName,
          );
    final selectedLatency =
        displayNode == null ? null : _latencyController.latencyFor(displayNode);
    final selectedCountryCode = displayNode == null
        ? null
        : _exitCountryCodes[displayNode.name] ??
            countryCodeForProxyNode(displayNode);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SsrvpnHomeOverview(
        isConnected: _isConnected,
        isConnecting: isConnectionTransition,
        selectedNode: displayNode,
        selectedLatency: selectedLatency,
        selectedCountryCode: selectedCountryCode,
        errorMessage: _errorMessage,
        connectionNotice: _connectivityWarning,
        publicIpv4: _publicIpInfo?.displayText,
        isRefreshingPublicIp: _isRefreshingPublicIp,
        publicIpError: _publicIpError,
        onToggleConnection: _handleConnectToggle,
        onOpenNodes: _openNodeSelection,
        onShowAbout: () => showSsrvpnAboutDialog(context),
        onShowTutorial: () => _showDesktopHomeTutorialDialog(context),
        onShowLogs: () => _showDesktopHomeLogsDialog(context),
        onRefreshPublicIp: () => unawaited(_refreshPublicIpInfo()),
      ),
    );
  }

  Future<void> _openNodeSelection() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => SsrvpnNodeSelectionPage(
          ownerStateListenable: Listenable.merge([
            _nodeSelectionRefresh,
            context.read<SettingsService>(),
          ]),
          nodesOf: () => _nodes,
          selectedNodeNameOf: () {
            final settings = context.read<SettingsService>().settings;
            return _isConnected
                ? HomeNodeController.resolveRuntimeSelectedNodeFrom(
                    _nodes,
                    _selectedNode?.name,
                  )?.name
                : HomeNodeController.resolveDefaultNodeFrom(
                    _nodes,
                    _disconnectedPreferredNodeName ??
                        settings.lastSelectedNodeName,
                  )?.name;
          },
          proxyModeOf: () => context.read<SettingsService>().settings.proxyMode,
          enableTunOf: () => context.read<SettingsService>().settings.enableTun,
          testingNodeNameOf: () => _testingNodeName,
          isBatchTestingOf: () => _isBatchTesting,
          isConnectingOf: () => _isConnectionTransitionActive(
            _clashService ?? context.read<ClashService>(),
          ),
          countryCodeOf: (node) =>
              _exitCountryCodes[node.name] ?? countryCodeForProxyNode(node),
          latencyOf: _latencyController.latencyFor,
          canSelectNode: (node) =>
              !_isConnected || _latencyController.canSelect(node),
          onClose: () => Navigator.of(routeContext).pop(),
          onRefresh: _loadInitialData,
          onTestAll: _handleTestAllLatency,
          onTestLatency: (node) =>
              _handleTestLatency(node.name, node.server, node.port),
          onSelectNode: _handleSelectNode,
          onProxyModeChanged: (proxyMode) => _applyNetworkSetting(
            (service) => service.updateProxyMode(proxyMode),
          ),
          onEnableTunChanged: (enableTun) => _applyNetworkSetting(
            (service) => service.updateEnableTun(enableTun),
          ),
          tunLabel: 'TUN 模式（需管理员权限）',
          onShowForceProxySites: _showForceProxySitesDialog,
          onShowLogs: () => _showDesktopHomeLogsDialog(context),
          onSecondaryTapDown: _showNodeContextMenu,
          onLongPressNode: (node) {
            unawaited(
              Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => NodeEditScreen(node: node),
                ),
              ),
            );
          },
        ),
      ),
    );
    if (mounted && !_disposed) setState(() {});
  }
}

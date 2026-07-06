part of desktop_home_screen;

bool _initialSubscriptionDialogInFlight = false;
int _lastEmptySubscriptionPromptRevision = -1;

/// 主屏幕 — 桌面优化
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  List<ProxyNode> _nodes = [];
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isBatchTesting = false;
  String? _errorMessage;
  String? _testingNodeName;
  ProxyNode? _selectedNode;
  PublicIpInfo? _publicIpInfo;
  bool _isRefreshingPublicIp = false;
  String? _publicIpError;
  final Set<String> _expandedSubscriptionGroups = {};

  final HomeLatencyController _latencyController = HomeLatencyController();
  final Map<String, String> _exitCountryCodes = {};
  Timer? _latencyBatchTimer;
  Timer? _publicIpTimer;
  int _lastRevision = -1;
  int _publicIpGeneration = 0;
  bool _disposed = false;
  bool _isResolvingExitCountries = false;
  bool _pendingExitCountryResolution = false;
  int _exitCountryResolveGeneration = 0;
  ClashService? _clashService;
  SubscriptionService? _subscriptionService;
  Timer? _updateCheckTimer;
  late AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInitialData());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final subService = context.read<SubscriptionService>();
    if (identical(_subscriptionService, subService)) return;
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

  Future<void> _reloadConfig() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final rawYaml = subService.rawYaml;
    if (rawYaml == null || rawYaml.isEmpty) return;

    setState(() => _isConnecting = true);
    try {
      final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
      if (nodes.isEmpty) throw Exception('未获取到可用节点');
      final preferredNode = _resolveDefaultNode(
        nodes,
        settingsService.settings.lastSelectedNodeName,
      );
      await clashService.stop();
      final runtimeSettings = await clashService.prepareForStart(
        settingsService.settings,
      );
      final config = clashService.generateClashConfig(
        rawYaml,
        runtimeSettings,
        preferredNodeName: preferredNode?.name,
      );
      await clashService.writeConfig(config);
      final success = await clashService.start();
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

  void _scheduleLatencyFlush() {
    _latencyBatchTimer?.cancel();
    _latencyBatchTimer = Timer(
      const Duration(milliseconds: 100),
      _flushPendingLatencies,
    );
  }

  void _flushPendingLatencies() {
    if (!_latencyController.hasPending || !mounted || _disposed) return;
    setState(() {
      _latencyController.flushTo(_nodes);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _latencyBatchTimer?.cancel();
    _publicIpTimer?.cancel();
    _updateCheckTimer?.cancel();
    _clashService?.removeStatusListener(_handleClashStatusChanged);
    _subscriptionService?.removeListener(_handleSubscriptionServiceChanged);
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    _clashService = clashService;
    final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
    final runtimeSelectedNode = clashService.isRunning
        ? await _resolveRuntimeSelectedNode(clashService, nodes)
        : null;
    if (nodes.isNotEmpty) {
      setState(() {
        _nodes = nodes;
        _lastRevision = subService.revision;
        if (clashService.isRunning) _selectedNode = runtimeSelectedNode;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_autoTestAllNodes());
      });
    }
    if (clashService.isRunning) {
      setState(() => _isConnected = true);
      _glowController.repeat();
      _schedulePublicIpRefresh();
    }

    clashService.addStatusListener(_handleClashStatusChanged);

    if (nodes.isEmpty) {
      _maybeShowInitialSubscriptionDialog(subService);
    }
  }

  void _handleClashStatusChanged() {
    final clashService = _clashService;
    if (clashService == null || !mounted || _disposed) return;
    final running = clashService.isRunning;
    if (_isConnected == running) return;
    setState(() {
      _isConnected = running;
      if (!running) {
        _latencyController.clear();
        _selectedNode = null;
        _resetPublicIpState();
        _exitCountryResolveGeneration++;
        _glowController.stop();
      } else {
        _glowController.repeat();
        _scheduleExitCountryResolution();
        _schedulePublicIpRefresh();
        unawaited(_syncSelectedNodeFromRuntime());
      }
    });
  }

  Future<void> _showInitialSubscriptionDialog() async {
    if (_initialSubscriptionDialogInFlight) return;
    _initialSubscriptionDialogInFlight = true;

    final controller = TextEditingController();
    String? inputError;
    bool isSubmitting = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        final titleColor =
            isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
        final subtitleColor =
            isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

        return StatefulBuilder(
          builder: (builderContext, setDialogState) {
            Future<void> submit() async {
              final input = controller.text.trim();
              final subService = builderContext.read<SubscriptionService>();
              final settingsService = builderContext.read<SettingsService>();
              final navigator = Navigator.of(dialogContext);
              final messenger = ScaffoldMessenger.of(builderContext);
              final validationError = _validateSubscriptionInput(
                input,
                subService,
              );
              if (validationError != null) {
                setDialogState(() => inputError = validationError);
                return;
              }

              setDialogState(() {
                inputError = null;
                isSubmitting = true;
              });

              try {
                final exists = subService.subscriptions.any(
                  (sub) => sub.url == input,
                );
                if (!exists) {
                  await subService.addSubscription(
                    subService.defaultSubscriptionName(input),
                    input,
                  );
                }

                final yaml = await subService.refreshAllSubscriptions();
                final nodes = HomeNodeController.runnableNodesFrom(
                  subService.allNodes,
                );
                if (yaml == null || yaml.trim().isEmpty || nodes.isEmpty) {
                  throw Exception('未获取到可用节点');
                }

                if (!mounted || _disposed) return;
                setState(() {
                  _nodes = nodes;
                  _lastRevision = subService.revision;
                  _selectedNode = _resolveDefaultNode(
                    nodes,
                    settingsService.settings.lastSelectedNodeName,
                  );
                });
                unawaited(_autoTestAllNodes());

                if (navigator.canPop()) navigator.pop();
                messenger.showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text('节点已更新，获取到 ${nodes.length} 个节点'),
                    backgroundColor: AppTheme.success,
                  ),
                );
              } catch (e) {
                if (!mounted || _disposed) return;
                final msg = e.toString().replaceFirst('Exception: ', '');
                setDialogState(() {
                  inputError = '更新失败: $msg';
                  isSubmitting = false;
                });
              }
            }

            return Dialog(
              backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withValues(
                                alpha: 22 / 255,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.rss_feed_rounded,
                              color: AppTheme.primary,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '添加订阅',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: titleColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '请粘贴你的SSR代码或订阅链接',
                        style: TextStyle(fontSize: 13, color: subtitleColor),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: 4,
                        enabled: !isSubmitting,
                        decoration: InputDecoration(
                          hintText: 'ssr:// 或 https://...',
                          prefixIcon: const Icon(Icons.link_rounded),
                          errorText: inputError,
                          filled: true,
                          fillColor: isDark
                              ? Colors.white.withValues(alpha: 6 / 255)
                              : Colors.black.withValues(alpha: 4 / 255),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark
                                  ? AppTheme.border
                                  : AppTheme.lightBorder,
                            ),
                          ),
                        ),
                        keyboardType: TextInputType.url,
                        onSubmitted: (_) {
                          if (!isSubmitting) submit();
                        },
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: isSubmitting
                                  ? null
                                  : () => Navigator.of(dialogContext).pop(),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: isSubmitting ? null : submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: isSubmitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('确定'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    _initialSubscriptionDialogInFlight = false;

    controller.dispose();
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

    final uri = Uri.tryParse(input);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
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

    if (wasConnected) {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      await clashService.stop();
      _resetPublicIpState();
    }

    await update(settingsService);
    clashService.updateSettings(settingsService.settings);

    if (!mounted || _disposed) return;
    setState(() {
      _isConnecting = false;
      _isConnected = false;
      _selectedNode = null;
      _latencyController.clear();
      _resetPublicIpState();
    });

    if (wasConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('网络设置已更新，请重新连接')));
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
    if (_isConnecting) return;
    final clashService = context.read<ClashService>();
    final subService = context.read<SubscriptionService>();
    final settingsService = context.read<SettingsService>();

    if (_isConnected) {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      await clashService.stop();
      if (!mounted) return;
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _latencyController.clear();
        _exitCountryResolveGeneration++;
        _resetPublicIpState();
        _glowController.stop();
      });
    } else {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      final rawYaml = subService.rawYaml;
      if (rawYaml == null || rawYaml.isEmpty) {
        setState(() {
          _errorMessage = '请先添加并刷新订阅';
          _isConnecting = false;
          _resetPublicIpState();
        });
        return;
      }
      try {
        final nodes = HomeNodeController.runnableNodesFrom(
          subService.allNodes,
        );
        if (nodes.isEmpty) {
          setState(() {
            _errorMessage = '订阅中没有可用节点，请刷新订阅';
            _isConnecting = false;
            _resetPublicIpState();
          });
          return;
        }
        final autoSelect = _resolveDefaultNode(
          nodes,
          settingsService.settings.lastSelectedNodeName,
        );
        final runtimeSettings = await clashService.prepareForStart(
          settingsService.settings,
        );
        final config = clashService.generateClashConfig(
          rawYaml,
          runtimeSettings,
          preferredNodeName: autoSelect?.name,
        );
        await clashService.writeConfig(config);
        final success = await clashService.start();
        ProxyNode? runtimeSelectedNode;
        if (!mounted) return;
        if (success) {
          if (autoSelect != null) {
            final switched = await clashService.switchSelectedProxy(
              autoSelect.name,
            );
            runtimeSelectedNode = await _resolveRuntimeSelectedNode(
              clashService,
              nodes,
            );
            if (switched && runtimeSelectedNode?.name == autoSelect.name) {
              await _rememberSelectedNode(autoSelect);
            }
          } else {
            runtimeSelectedNode = await _resolveRuntimeSelectedNode(
              clashService,
              nodes,
            );
          }
          final connectivityWarning =
              await clashService.verifyUserConnectivity();
          setState(() {
            _isConnected = true;
            _isConnecting = false;
            _errorMessage = connectivityWarning;
            _nodes = nodes;
            _selectedNode = runtimeSelectedNode;
          });
          _glowController.repeat();
          _scheduleExitCountryResolution();
          _schedulePublicIpRefresh();
          unawaited(_autoTestAllNodes());
          _checkUpdateDelayed();
        } else {
          final reason = clashService.lastStartError ?? '无法启动核心';
          recordDesktopConnectionFailure('Connection failed: $reason');
          setState(() {
            _errorMessage = '连接失败: $reason';
            _isConnecting = false;
            _resetPublicIpState();
          });
        }
      } catch (e, stack) {
        recordDesktopConnectionFailure(
          'Connection failed',
          error: e,
          stack: stack,
        );
        if (!mounted) return;
        final msg = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _errorMessage = '连接失败: $msg';
          _isConnecting = false;
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
        final result = await UpdateService.checkForUpdate(currentVersion);
        if (result != null && mounted && _isConnected) {
          final (latestVersion, downloadUrl, changelog) = result;
          UpdateService.showUpdateDialog(
            context,
            latestVersion: latestVersion,
            currentVersion: currentVersion,
            downloadUrl: downloadUrl,
            changelog: changelog,
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

  Future<void> _autoTestAllNodes() async {
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

  Future<void> _handleTestAllLatency() async {
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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>().settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _DesktopHomeDashboard(
        isDark: isDark,
        textColor: textColor,
        subColor: subColor,
        settings: settings,
        nodeList: _buildNodeList(textColor, subColor, isDark),
        isConnected: _isConnected,
        isConnecting: _isConnecting,
        errorMessage: _errorMessage,
        publicIpInfo: _publicIpInfo,
        isRefreshingPublicIp: _isRefreshingPublicIp,
        publicIpError: _publicIpError,
        glowAnimation: _glowController,
        onToggleConnection: _handleConnectToggle,
        onShowTutorial: () => _showDesktopHomeTutorialDialog(context),
        onShowForceProxySites: _showForceProxySitesDialog,
        onShowLogs: () => _showDesktopHomeLogsDialog(context),
        onRefreshPublicIp: () => unawaited(_refreshPublicIpInfo()),
        onProxyModeChanged: (proxyMode) {
          _applyNetworkSetting(
            (service) => service.updateProxyMode(proxyMode),
          );
        },
        onEnableTunChanged: (enableTun) {
          _applyNetworkSetting(
            (service) => service.updateEnableTun(enableTun),
          );
        },
      ),
    );
  }

  Widget _buildNodeList(Color textColor, Color subColor, bool isDark) {
    return _DesktopHomeNodeList(
      nodes: _nodes,
      latencyController: _latencyController,
      exitCountryCodes: _exitCountryCodes,
      expandedSubscriptionGroups: _expandedSubscriptionGroups,
      selectedNode: _selectedNode,
      testingNodeName: _testingNodeName,
      isConnecting: _isConnecting,
      isBatchTesting: _isBatchTesting,
      isConnected: _isConnected,
      textColor: textColor,
      subColor: subColor,
      isDark: isDark,
      onTestAllLatency: _handleTestAllLatency,
      onTestLatency: (node) =>
          _handleTestLatency(node.name, node.server, node.port),
      onSelectNode: _handleSelectNode,
      onSecondaryTapDown: _showNodeContextMenu,
      onToggleSubscriptionGroup: (title, expanded) {
        setState(() {
          if (!expanded) {
            _expandedSubscriptionGroups.add(title);
          } else {
            _expandedSubscriptionGroups.remove(title);
          }
        });
      },
    );
  }
}

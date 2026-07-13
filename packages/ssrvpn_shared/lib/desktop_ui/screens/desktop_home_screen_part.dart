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
    final cancelledWhileConnecting =
        _isConnecting && !clashService.connectionDesired;
    if (_isConnected == running && !cancelledWhileConnecting) return;
    setState(() {
      _isConnected = running;
      if (cancelledWhileConnecting) _isConnecting = false;
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
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      if (wasConnected) {
        clashService.requestConnectionIntent(false);
        await clashService.stop();
        _resetPublicIpState();
      }

      await update(settingsService);
      clashService.updateSettings(settingsService.settings);

      if (!mounted || _disposed) return;
      setState(() {
        _isConnected = false;
        _selectedNode = null;
        _latencyController.clear();
        _resetPublicIpState();
      });

      if (wasConnected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('网络设置已更新，请重新连接')),
        );
      }
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

    if (_isConnecting) {
      clashService.requestConnectionIntent(false);
      try {
        await clashService.stop();
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
              _glowController.stop();
            }
          });
        }
      }
      return;
    }

    if (_isConnected) {
      clashService.requestConnectionIntent(false);
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      try {
        await clashService.stop();
        if (!mounted || _disposed) return;
        setState(() {
          _isConnected = false;
          _latencyController.clear();
          _exitCountryResolveGeneration++;
          _resetPublicIpState();
          _glowController.stop();
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
          setState(() {
            _errorMessage = '请先添加并刷新订阅';
            _isConnecting = false;
            _resetPublicIpState();
          });
          return;
        }
        final nodes = HomeNodeController.runnableNodesFrom(
          subService.allNodes,
        );
        if (nodes.isEmpty) {
          clashService.requestConnectionIntent(false);
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
        if (!clashService.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        )) {
          return;
        }
        final success = await clashService.start();
        if (!clashService.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        )) {
          return;
        }
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
          if (!clashService.isRunning ||
              !clashService.isConnectionIntentCurrent(
                connectionGeneration,
                connected: true,
              )) {
            if (!clashService.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            )) {
              return;
            }
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
          setState(() {
            _isConnected = true;
            _isConnecting = false;
            _errorMessage = null;
            _nodes = nodes;
            _selectedNode = runtimeSelectedNode;
          });
          _glowController.repeat();
          _scheduleExitCountryResolution();
          _schedulePublicIpRefresh();
          unawaited(_autoTestAllNodes());
          _checkUpdateDelayed();

          // Core/API/system proxy success is the user-visible connection
          // boundary. Connectivity probing is advisory and must not leave the
          // UI looking stuck on slower or probe-blocking networks.
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
        } else {
          final isCurrent = clashService.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          );
          if (!isCurrent) return;
          clashService.requestConnectionIntent(false);
          final reason = clashService.lastStartError ?? '无法启动核心';
          recordDesktopConnectionFailure('Connection failed: $reason');
          setState(() {
            _errorMessage = '连接失败: $reason';
            _isConnecting = false;
            _resetPublicIpState();
          });
        }
      } catch (e, stack) {
        final isCurrent = clashService.isConnectionIntentCurrent(
          requestedGeneration,
          connected: true,
        );
        if (!isCurrent) return;
        clashService.requestConnectionIntent(false);
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

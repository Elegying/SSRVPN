part of 'home_screen.dart';

extension _AndroidHomeConnectionActions on HomeScreenState {
  Future<void> _reloadConfig() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final connectionGeneration = clashService.captureAutomaticRestartIntent();
    if (connectionGeneration == null) return;
    await clashService.runIntentionalReloadTransition(
      () => _reloadConfigTransition(
        subService,
        clashService,
        settingsService,
        connectionGeneration,
      ),
    );
  }

  Future<void> _reloadConfigTransition(
    SubscriptionService subService,
    ClashService clashService,
    SettingsService settingsService,
    int connectionGeneration,
  ) async {
    if (!clashService.isConnectionIntentCurrent(
      connectionGeneration,
      connected: true,
    )) {
      return;
    }
    final settings = settingsService.settings;
    final orch = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subService,
    );

    _updateHomeState(() => _isConnecting = true);
    try {
      final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
      if (nodes.isEmpty) {
        _updateHomeState(() {
          _isConnected = clashService.isRunning;
          _isConnecting = false;
          _errorMessage = '订阅中没有可用节点，已保留当前连接';
        });
        return;
      }
      final preferredNode = _resolveDefaultNode(
        nodes,
        settings.lastSelectedNodeName,
      );
      clashService.updateSettings(settings);
      await clashService.stop();
      if (!clashService.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        return;
      }
      if (mounted && !_disposed) {
        _updateHomeState(() {
          _isConnected = false;
          _connectionNotice = null;
        });
      }
      final outcome = await orch.connect(
        preferredNode?.name,
        connectionGeneration: connectionGeneration,
      );
      if (!clashService.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        return;
      }
      final connected = clashService.isRunning;
      if (mounted && !_disposed) {
        if (!connected) clashService.requestConnectionIntent(false);
        ProxyNode? connectedNode;
        var preferredNodePersisted = true;
        if (connected) {
          connectedNode = outcome.preferredNodeSwitchSucceeded
              ? preferredNode
              : HomeNodeController.resolveRuntimeSelectedNodeFrom(
                  nodes,
                  outcome.runtimeNodeName,
                );
          if (connectedNode != null) {
            preferredNodePersisted = await _rememberSelectedNode(
              connectedNode,
              shouldContinue: () => clashService.isConnectionIntentCurrent(
                connectionGeneration,
                connected: true,
              ),
            );
          }
        }
        if (!clashService.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        )) {
          return;
        }
        if (!mounted || _disposed) return;
        final feedback = resolveAndroidConnectionFeedback(
          connected: connected,
          result: connected && !preferredNodePersisted
              ? '已连接，但首选节点保存失败'
              : outcome.message,
          runtimeNotice:
              connected ? clashService.underlyingNetworkNotice : null,
        );
        _updateHomeState(() {
          _isConnected = connected;
          _connectionNotice = feedback.connectionNotice;
          _isConnecting = false;
          _errorMessage = feedback.errorMessage;
          _nodes = nodes;
          _selectedNode = connected ? connectedNode : null;
          if (!connected) _resetPublicIpState();
        });
        if (connected) _schedulePublicIpRefresh();
      }
    } catch (e) {
      if (mounted && !_disposed) {
        final cancelled = !clashService.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        );
        if (cancelled) return;
        final stillRunning = clashService.isRunning;
        if (!stillRunning) clashService.requestConnectionIntent(false);
        _updateHomeState(() {
          _isConnected = stillRunning;
          _isConnecting = false;
          _errorMessage = stillRunning
              ? '连接重载失败，已保留当前连接: ${_userFriendlyError(e)}'
              : '连接重载失败: ${_userFriendlyError(e)}';
          if (!_isConnected) _resetPublicIpState();
        });
      }
    }
  }

  Future<void> _handleConnectToggle() async {
    final clashService = context.read<ClashService>();
    final subService = context.read<SubscriptionService>();
    final settingsService = context.read<SettingsService>();

    if (_isConnecting) {
      clashService.requestConnectionIntent(false);
      try {
        await clashService.stop();
      } catch (e) {
        if (mounted && !_disposed) {
          _updateHomeState(() {
            _errorMessage = '取消连接失败: ${_userFriendlyError(e)}';
          });
        }
      } finally {
        if (mounted && !_disposed) {
          _updateHomeState(() {
            _isConnected = clashService.isRunning;
            _connectionNotice =
                _isConnected ? clashService.underlyingNetworkNotice : null;
            _isConnecting = false;
            _nativeRecoveryInProgress = false;
            if (!_isConnected) {
              _latencyController.clear();
              _resetPublicIpState();
            }
          });
        }
      }
      return;
    }

    if (_isConnected) {
      clashService.requestConnectionIntent(false);
      _updateHomeState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      try {
        await clashService.stop();
        if (!mounted || _disposed) return;
        _updateHomeState(() {
          _isConnected = false;
          _connectionNotice = null;
          _latencyController.clear();
          _resetPublicIpState();
        });
      } catch (e) {
        if (mounted && !_disposed) {
          _updateHomeState(() {
            _isConnected = clashService.isRunning;
            _connectionNotice =
                _isConnected ? clashService.underlyingNetworkNotice : null;
            _errorMessage = '断开连接失败: ${_userFriendlyError(e)}';
          });
        }
      } finally {
        if (mounted && !_disposed) {
          _updateHomeState(() => _isConnecting = false);
        }
      }
    } else {
      _updateHomeState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      int? connectionGeneration;
      try {
        final nodes = HomeNodeController.runnableNodesFrom(
          subService.allNodes,
        );
        if (nodes.isEmpty) {
          _updateHomeState(() {
            _errorMessage = '订阅中没有可用节点，请刷新订阅';
            _isConnecting = false;
            _resetPublicIpState();
          });
          return;
        }
        final autoSelect = _resolveDefaultNode(
          nodes,
          resolveAndroidPreferredNodeName(
            selectedNodeName: _selectedNode?.name,
            rememberedNodeName: settingsService.settings.lastSelectedNodeName,
          ),
        );
        connectionGeneration = clashService.requestConnectionIntent(true);
        final orchestrator = ConnectionOrchestrator(
          clashService: clashService,
          settingsService: settingsService,
          subscriptionService: subService,
        );
        final outcome = await clashService.runConnectionTransition(
          () async {
            if (!clashService.isConnectionIntentCurrent(
              connectionGeneration!,
              connected: true,
            )) {
              return const AndroidConnectionOutcome();
            }
            return orchestrator.connect(
              autoSelect?.name,
              connectionGeneration: connectionGeneration,
            );
          },
        );
        if (!clashService.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        )) {
          return;
        }
        final connected = clashService.isRunning;
        if (!connected) {
          rollbackFailedAndroidConnectionIntent(
            clashService,
            connectionGeneration,
          );
        }
        if (!mounted || _disposed) return;
        if (connected) {
          var preferredNodePersisted = true;
          final connectedNode = outcome.preferredNodeSwitchSucceeded
              ? autoSelect
              : HomeNodeController.resolveRuntimeSelectedNodeFrom(
                  nodes,
                  outcome.runtimeNodeName,
                );
          if (connectedNode != null) {
            preferredNodePersisted = await _rememberSelectedNode(
              connectedNode,
              shouldContinue: () => clashService.isConnectionIntentCurrent(
                connectionGeneration!,
                connected: true,
              ),
            );
          }
          if (!clashService.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          )) {
            return;
          }
          if (!clashService.isRunning) {
            rollbackFailedAndroidConnectionIntent(
              clashService,
              connectionGeneration,
            );
            _updateHomeState(() {
              _isConnected = false;
              _connectionNotice = null;
              _isConnecting = false;
              _errorMessage = userFriendlyAndroidConnectionError(
                outcome.message ?? '连接已中断，请重新连接',
              );
              _resetPublicIpState();
            });
            return;
          }
          final feedback = resolveAndroidConnectionFeedback(
            connected: true,
            result: preferredNodePersisted ? outcome.message : '已连接，但首选节点保存失败',
            runtimeNotice: clashService.underlyingNetworkNotice,
          );
          _updateHomeState(() {
            _isConnected = true;
            _connectionNotice = feedback.connectionNotice;
            _isConnecting = false;
            _errorMessage = feedback.errorMessage;
            _nodes = nodes;
            _selectedNode = connectedNode;
          });
          _schedulePublicIpRefresh();
          unawaited(_autoTestAllNodes());
          _checkUpdateDelayed();
        } else {
          final feedback = resolveAndroidConnectionFeedback(
            connected: false,
            result: outcome.message,
            runtimeNotice: null,
          );
          _updateHomeState(() {
            _errorMessage = feedback.errorMessage;
            _isConnecting = false;
            _resetPublicIpState();
          });
        }
      } catch (e) {
        final cancelled = connectionGeneration != null &&
            !clashService.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            );
        if (cancelled) return;
        rollbackFailedAndroidConnectionIntent(
          clashService,
          connectionGeneration,
        );
        if (!mounted || _disposed) return;
        _updateHomeState(() {
          _errorMessage = '连接失败: ${_userFriendlyError(e)}';
          _isConnected = clashService.isRunning;
          _connectionNotice =
              _isConnected ? clashService.underlyingNetworkNotice : null;
          _isConnecting = false;
          if (!_isConnected) _resetPublicIpState();
        });
      }
    }
  }

  String _userFriendlyError(Object error) {
    return userFriendlyAndroidConnectionError(error);
  }

  Future<void> _handleProxyModeChanged(String mode) async {
    final settingsService = context.read<SettingsService>();
    final clashService = context.read<ClashService>();
    final targetMode = mode == 'global' ? ProxyMode.global : ProxyMode.rule;
    if (_isConnecting || settingsService.settings.proxyMode == targetMode) {
      return;
    }

    final shouldReload = _isConnected || clashService.isRunning;
    try {
      if (!shouldReload) {
        await clashService.invalidateIdleNativeConnectionSnapshot();
      }
      await settingsService.setProxyMode(mode);
    } catch (error) {
      AppLogger.warning('ProxyMode', '保存代理模式失败: $error');
      if (!mounted || _disposed) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text('代理模式保存失败，请重试'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    if (!mounted || _disposed) return;
    clashService.updateSettings(settingsService.settings);

    if (shouldReload) {
      await _reloadConfig();
    }
  }

  Future<void> _showForceProxySitesDialog() async {
    final settings = context.read<SettingsService>().settings;
    final savedSites = AppSettings.normalizeForceProxySites(
      settings.forceProxySites,
    );
    final sites = await ForceProxySitesDialog.show(
      context,
      savedSites: savedSites,
    );
    if (sites == null || !mounted || _disposed) return;
    try {
      await _applyForceProxySites(sites);
    } catch (error) {
      AppLogger.warning('ForceProxySites', '保存强制代理网站失败: $error');
      if (!mounted || _disposed) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text('强制代理网站保存失败，请重试'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _applyForceProxySites(List<String> sites) async {
    final settingsService = context.read<SettingsService>();
    final clashService = context.read<ClashService>();
    final normalizedSites = AppSettings.normalizeForceProxySites(sites);
    final settingsChanged =
        settingsService.settings.copyWith(forceProxySites: normalizedSites) !=
            settingsService.settings;
    final shouldReload =
        (_isConnected || clashService.isRunning) && !_isConnecting;
    if (settingsChanged && !shouldReload) {
      await clashService.invalidateIdleNativeConnectionSnapshot();
    }
    await settingsService.updateForceProxySites(normalizedSites);
    clashService.updateSettings(settingsService.settings);

    var reloadSucceeded = false;
    if (shouldReload) {
      await _reloadConfig();
      reloadSucceeded =
          mounted && !_disposed && _isConnected && clashService.isRunning;
    }
    if (!mounted || _disposed) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
        content: Text(
          shouldReload
              ? reloadSucceeded
                  ? '强制代理网站已实时生效'
                  : '强制代理网站已保存，当前连接重载失败，请重新连接'
              : '强制代理网站已保存',
        ),
        backgroundColor:
            shouldReload && !reloadSucceeded ? AppTheme.warningColor : null,
        duration: const Duration(seconds: 4),
      ),
    );
  }
}

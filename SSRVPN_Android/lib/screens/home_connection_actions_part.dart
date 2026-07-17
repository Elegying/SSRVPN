part of 'home_screen.dart';

extension _AndroidHomeConnectionActions on HomeScreenState {
  Future<void> _reloadConfig() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final settings = settingsService.settings;
    final connectionGeneration = clashService.captureAutomaticRestartIntent();
    if (connectionGeneration == null) return;

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
      final result = await orch.connect(
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
        _updateHomeState(() {
          _isConnected = connected;
          _isConnecting = false;
          _errorMessage = connected ? result : result ?? '连接重载失败: 无法启动VPN核心';
          _nodes = nodes;
          _selectedNode = connected ? preferredNode : null;
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
            _isConnecting = false;
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
          _latencyController.clear();
          _resetPublicIpState();
        });
        _glowController.stop();
      } catch (e) {
        if (mounted && !_disposed) {
          _updateHomeState(() {
            _isConnected = clashService.isRunning;
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
          settingsService.settings.lastSelectedNodeName,
        );
        connectionGeneration = clashService.requestConnectionIntent(true);
        final result = await _orchestrator.connect(
          autoSelect?.name,
          connectionGeneration: connectionGeneration,
        );
        if (!mounted || _disposed) return;
        if (!clashService.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        )) {
          return;
        }
        final connected = clashService.isRunning;
        if (connected) {
          if (autoSelect != null) {
            await _rememberSelectedNode(
              autoSelect,
              shouldContinue: () => clashService.isConnectionIntentCurrent(
                connectionGeneration!,
                connected: true,
              ),
            );
          }
          _updateHomeState(() {
            _isConnected = true;
            _isConnecting = false;
            _errorMessage = result;
            _nodes = nodes;
            _selectedNode = autoSelect;
          });
          _glowController.repeat();
          _schedulePublicIpRefresh();
          unawaited(_autoTestAllNodes());
          _checkUpdateDelayed();
        } else {
          _updateHomeState(() {
            _errorMessage = result ?? '连接失败: 无法启动VPN核心';
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
        if (!mounted || _disposed) return;
        if (cancelled) return;
        _updateHomeState(() {
          _errorMessage = '连接失败: ${_userFriendlyError(e)}';
          _isConnected = clashService.isRunning;
          _isConnecting = false;
          if (!_isConnected) _resetPublicIpState();
        });
      }
    }
  }

  String _userFriendlyError(Object error) {
    final msg = error.toString();
    if (msg.contains('TimeoutException') ||
        msg.contains('timeout') ||
        msg.contains('超时')) {
      return '连接超时，请检查网络后重试';
    }
    if (msg.contains('SocketException') ||
        msg.contains('Network') ||
        msg.contains('Connection refused')) {
      return '网络连接失败，请检查网络设置';
    }
    if (msg.contains('HttpException') || msg.contains('HTTP')) {
      return '服务器响应异常，请稍后重试';
    }
    if (msg.contains('HandshakeException') ||
        msg.contains('TLS') ||
        msg.contains('Certificate')) {
      return '安全连接失败，请检查网络环境';
    }
    return msg.replaceFirst('Exception: ', '');
  }

  Future<void> _handleProxyModeChanged(String mode) async {
    final settingsService = context.read<SettingsService>();
    final targetMode = mode == 'global' ? ProxyMode.global : ProxyMode.rule;
    if (_isConnecting || settingsService.settings.proxyMode == targetMode) {
      return;
    }

    await settingsService.setProxyMode(mode);
    if (!mounted || _disposed) return;
    context.read<ClashService>().updateSettings(settingsService.settings);

    if (_isConnected) {
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

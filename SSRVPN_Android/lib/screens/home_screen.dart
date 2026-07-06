import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../services/settings_service.dart';
import '../services/notification_service.dart';
import '../services/update_service.dart';
import '../services/connection_orchestrator.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/connection_button.dart';
import '../widgets/force_proxy_sites_dialog.dart';
import '../widgets/glass_container.dart';
import '../widgets/home_node_list.dart';
import '../widgets/proxy_mode_selector.dart';
import 'node_edit_screen.dart';

part 'home_dashboard_part.dart';
part 'home_dialogs_part.dart';

/// 主屏幕 — 移动端优化设计
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

const _homeTutorialSteps = [
  _TutorialStepData('点击底部「订阅」标签，进入订阅管理页面'),
  _TutorialStepData('在输入框中粘贴我给你的订阅代码，点击「添加」'),
  _TutorialStepData('添加成功后点击「全部刷新」，等待节点加载完成'),
  _TutorialStepData('返回主页，点击连接按钮即可使用'),
  _TutorialStepData('首次连接会弹出系统权限弹窗，选择「确定」允许即可'),
];

class HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<ProxyNode> _nodes = [];
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isBatchTesting = false;
  String? _errorMessage;
  String? _testingNodeName;
  ProxyNode? _selectedNode;
  final Set<String> _expandedSubscriptionGroups = {};

  final HomeLatencyController _latencyController = HomeLatencyController();
  Timer? _latencyBatchTimer;
  int _lastRevision = -1;
  bool _disposed = false;
  ClashService? _registeredClashService;
  SubscriptionService? _subscriptionService;
  late final VoidCallback _onClashAutoConnect = _handleClashAutoConnect;
  late final VoidCallback _onClashStatusChanged = _handleClashStatusChanged;

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
    if (sync.shouldPromptForImport) return true;
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
    final settings = settingsService.settings;

    final orch = ConnectionOrchestrator(
      clashService: clashService,
      notificationService: NotificationService.instance,
      settingsService: settingsService,
      subscriptionService: subService,
    );

    setState(() => _isConnecting = true);
    try {
      final nodes = List<ProxyNode>.from(subService.allNodes);
      final preferredNode = _resolveDefaultNode(
        nodes,
        settings.lastSelectedNodeName,
      );
      clashService.updateSettings(settings);
      await clashService.stop();
      final result = await orch.connect(preferredNode?.name);
      if (mounted && !_disposed) {
        setState(() {
          _isConnected = result == null;
          _isConnecting = false;
          _errorMessage = result;
          _nodes = nodes;
          _selectedNode = result == null ? preferredNode : null;
        });
      }
    } catch (e) {
      if (mounted && !_disposed) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _errorMessage = '连接重载失败: ${_userFriendlyError(e)}';
        });
      }
    }
  }

  void _scheduleLatencyFlush() {
    _latencyBatchTimer?.cancel();
    _latencyBatchTimer =
        Timer(const Duration(milliseconds: 100), _flushPendingLatencies);
  }

  void _flushPendingLatencies() {
    if (!_latencyController.hasPending || !mounted || _disposed) return;
    setState(() {
      _latencyController.flushTo(_nodes);
    });
  }

  /// 供外部（app.dart）在页面切换回来时强制刷新节点列表
  void refreshNodes() {
    if (_disposed || !mounted) return;
    final subService = context.read<SubscriptionService>();
    final latestNodes = List<ProxyNode>.from(subService.allNodes);
    final revision = subService.revision;
    if (revision != _lastRevision || _nodes.length != latestNodes.length) {
      _lastRevision = revision;
      setState(() {
        _nodes = latestNodes;
        // 如果已连接且有节点，更新选中节点
        if (_isConnected && latestNodes.isNotEmpty && _selectedNode != null) {
          final match = latestNodes.cast<ProxyNode?>().firstWhere(
                (n) => n?.name == _selectedNode!.name,
                orElse: () => null,
              );
          if (match == null) {
            _selectedNode = _resolveDefaultNode(
              latestNodes,
              context.read<SettingsService>().settings.lastSelectedNodeName,
            );
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final clashService = _registeredClashService;
    if (clashService != null) {
      if (identical(clashService.onAutoConnect, _onClashAutoConnect)) {
        clashService.onAutoConnect = null;
      }
      if (identical(clashService.onStatusChanged, _onClashStatusChanged)) {
        clashService.onStatusChanged = null;
      }
    }
    _latencyBatchTimer?.cancel();
    _subscriptionService?.removeListener(_handleSubscriptionServiceChanged);
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    if (subService.allNodes.isNotEmpty) {
      final nodes = List<ProxyNode>.from(subService.allNodes);
      setState(() {
        _nodes = nodes;
        _lastRevision = subService.revision;
        if (clashService.isRunning) {
          _selectedNode = _resolveDefaultNode(
            nodes,
            settingsService.settings.lastSelectedNodeName,
          );
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_autoTestAllNodes());
      });
    }
    if (clashService.isRunning) {
      setState(() => _isConnected = true);
      _glowController.repeat();
    }

    _registeredClashService = clashService;
    clashService.onAutoConnect = _onClashAutoConnect;

    final pendingAutoConnect = await clashService.consumePendingAutoConnect();
    if (pendingAutoConnect && !_isConnected && mounted) {
      unawaited(_handleConnectToggle());
    }

    clashService.onStatusChanged = _onClashStatusChanged;
  }

  void _handleClashAutoConnect() {
    if (!_isConnected && mounted && !_disposed) {
      unawaited(_handleConnectToggle());
    }
  }

  void _handleClashStatusChanged() {
    final clashService = _registeredClashService;
    if (!mounted || _disposed || clashService == null) return;
    final running = clashService.isRunning;
    if (_isConnected == running) return;
    setState(() {
      _isConnected = running;
      if (!running) {
        _latencyController.clear();
        _selectedNode = null;
      }
    });
    if (running) {
      _glowController.repeat();
    } else {
      _glowController.stop();
    }
  }

  ConnectionOrchestrator get _orchestrator => ConnectionOrchestrator(
        clashService: context.read<ClashService>(),
        notificationService: NotificationService.instance,
        settingsService: context.read<SettingsService>(),
        subscriptionService: context.read<SubscriptionService>(),
      );

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
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _latencyController.clear();
      });
      _glowController.stop();
    } else {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      try {
        final nodes = List<ProxyNode>.from(subService.allNodes);
        final autoSelect = _resolveDefaultNode(
          nodes,
          settingsService.settings.lastSelectedNodeName,
        );
        final result = await _orchestrator.connect(autoSelect?.name);
        if (!mounted) return;
        if (result == null) {
          if (autoSelect != null) {
            await _rememberSelectedNode(autoSelect);
          }
          setState(() {
            _isConnected = true;
            _isConnecting = false;
            _nodes = nodes;
            _selectedNode = autoSelect;
          });
          _glowController.repeat();
          unawaited(_autoTestAllNodes());
          _checkUpdateDelayed();
        } else {
          setState(() {
            _errorMessage = result;
            _isConnecting = false;
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _errorMessage = '连接失败: ${_userFriendlyError(e)}';
          _isConnecting = false;
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

  void _checkUpdateDelayed() {
    Future.delayed(const Duration(seconds: 10), () async {
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
            margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
            content: Text('请先连接VPN'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }
    final clashService = context.read<ClashService>();
    final ok = await clashService.switchSelectedProxy(node.name);
    if (ok) {
      await _rememberSelectedNode(node);
      await _writePreferredNodeConfigForTile(node);
      if (mounted) setState(() => _selectedNode = node);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text(ok ? '已切换: ${node.name}' : '切换失败: ${node.name}'),
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

  Future<void> _rememberSelectedNode(ProxyNode node) async {
    final settingsService = context.read<SettingsService>();
    if (settingsService.settings.lastSelectedNodeName == node.name) return;
    await settingsService.setLastSelectedNodeName(node.name);
  }

  Future<void> _writePreferredNodeConfigForTile(ProxyNode node) async {
    final rawYaml = context.read<SubscriptionService>().rawYaml;
    if (rawYaml == null || rawYaml.trim().isEmpty) return;
    final settingsService = context.read<SettingsService>();
    try {
      await context.read<ClashService>().writePreferredNodeConfig(
            rawYaml,
            settingsService.settings,
            node.name,
          );
    } catch (e) {
      AppLogger.warning('Tile', '更新默认节点配置失败: $e');
    }
  }

  Future<void> _autoTestAllNodes() async {
    if (_nodes.isEmpty) return;
    final clashService = context.read<ClashService>();
    setState(() => _isBatchTesting = true);
    _latencyController.clearPending();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _latencyController.queue(name, latency);
      _scheduleLatencyFlush();
    });
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
    setState(() => _isBatchTesting = true);
    _latencyController.clearPending();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _latencyController.queue(name, latency);
      _scheduleLatencyFlush();
    });
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

  // ── 设置入口已移除，关键设置项融入首页 ──

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = context.watch<SettingsService>().settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _AndroidHomeDashboard(
        isDark: isDark,
        textColor: textColor,
        subColor: subColor,
        settings: settings,
        nodeList: _buildNodeList(textColor, subColor, isDark),
        isConnected: _isConnected,
        isConnecting: _isConnecting,
        errorMessage: _errorMessage,
        glowAnimation: _glowController,
        onToggleConnection: _handleConnectToggle,
        onShowTutorial: () => _showAndroidHomeTutorialDialog(context),
        onShowForceProxySites: _showForceProxySitesDialog,
        onShowLogs: () => _showAndroidHomeLogsSheet(context),
        onProxyModeChanged: _handleProxyModeChanged,
      ),
    );
  }

  Widget _buildNodeList(Color textColor, Color subColor, bool isDark) {
    return HomeNodeList(
      nodes: _nodes,
      latencyController: _latencyController,
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
      onLongPressNode: _editNode,
      onEditNode: _editNode,
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

class _TutorialStepData {
  final String text;
  const _TutorialStepData(this.text);
}

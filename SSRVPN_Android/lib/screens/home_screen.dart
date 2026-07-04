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
import '../widgets/liquid_glass.dart' hide GlassInputDecoration;
import '../widgets/node_list_tile.dart';
import '../widgets/proxy_mode_selector.dart';
import 'node_edit_screen.dart';

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

  final Map<String, int> _latencies = {};
  Timer? _latencyBatchTimer;
  final Map<String, int> _pendingLatencies = {};
  int _lastRevision = -1;
  bool _disposed = false;
  ClashService? _registeredClashService;
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

  void _onSubscriptionChanged(SubscriptionService subService) {
    final controller = HomeNodeController(
      nodes: _nodes,
      latencies: _latencies,
      lastRevision: _lastRevision,
      selectedNode: _selectedNode,
    );
    final sync = controller.syncSubscriptionSnapshot(
      revision: subService.revision,
      allNodes: subService.allNodes,
    );
    if (!sync.changed) return;
    _lastRevision = controller.lastRevision;
    _nodes = controller.nodes;
    if (sync.shouldPromptForImport) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      if (!sync.isFirstSync && _isConnected) {
        unawaited(_reloadConfig());
      } else {
        unawaited(_autoTestAllNodes());
      }
    });
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
    if (_pendingLatencies.isEmpty || !mounted || _disposed) return;
    final batch = Map<String, int>.from(_pendingLatencies);
    _pendingLatencies.clear();
    setState(() {
      HomeNodeController.applyLatenciesTo(_nodes, _latencies, batch);
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
        _latencies.clear();
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
        _latencies.clear();
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
        HomeNodeController.applyLatenciesTo(
          _nodes,
          _latencies,
          {nodeName: latency},
        );
      });
      _sortNodesByLatency();
    }
  }

  Future<void> _handleSelectNode(ProxyNode node) async {
    if (!HomeNodeController.canSelectNode(node, _latencies)) return;
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
      _latencies.remove(node.name);
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
    _pendingLatencies.clear();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _pendingLatencies[name] = latency;
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
    _pendingLatencies.clear();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _pendingLatencies[name] = latency;
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
      _nodes = HomeNodeController.timeoutLast(_nodes, _latencies);
    });
  }

  // ── 设置入口已移除，关键设置项融入首页 ──

  void _showTutorial(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: GlassContainer(
          borderRadius: 16,
          enablePress: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(ctx).size.width * 0.88,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              AppTheme.primaryColor,
                              AppTheme.accentColor
                            ],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.menu_book_rounded,
                            color: Colors.white, size: 20),
                      ),
                      SizedBox(width: 12),
                      Text('使用教程',
                          style: TextStyle(
                              fontSize: Responsive.sp(18),
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? AppTheme.darkTextPrimary
                                  : AppTheme.lightTextPrimary)),
                    ],
                  ),
                  SizedBox(height: 20),
                  for (var i = 0; i < _homeTutorialSteps.length; i++) ...[
                    _TutorialStep(
                      step: '${i + 1}',
                      text: _homeTutorialSteps[i].text,
                    ),
                    if (i != _homeTutorialSteps.length - 1)
                      SizedBox(height: 12),
                  ],
                  SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        backgroundColor: AppTheme.primaryColor
                            .withValues(alpha: (isDark ? 25 : 15) / 255),
                      ),
                      child: Text('知道了',
                          style: TextStyle(
                              fontSize: Responsive.sp(14),
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryColor)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showLogs(BuildContext context) {
    final clashService = context.read<ClashService>();
    final logs = clashService.recentLogs;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.7,
        decoration: BoxDecoration(
          color: const Color(0xFF0E1018),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          border: Border.all(color: AppTheme.darkBorder),
        ),
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.darkBorder)),
              ),
              child: Row(
                children: [
                  Icon(Icons.bug_report,
                      size: 18, color: AppTheme.warningColor),
                  SizedBox(width: 8),
                  Text('运行日志',
                      style: TextStyle(
                          fontSize: Responsive.sp(16),
                          fontWeight: FontWeight.w600,
                          color: AppTheme.darkTextPrimary)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.copy,
                        size: 18, color: AppTheme.darkTextSecondary),
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: clashService.recentLogs));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
                            content: Text('日志已复制'),
                          ),
                        );
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        size: 18, color: AppTheme.darkTextSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(14),
                child: SelectableText(
                  logs.isEmpty ? '暂无日志' : logs,
                  style: TextStyle(
                    fontSize: Responsive.sp(12),
                    fontFamily: 'monospace',
                    color: AppTheme.darkTextSecondary,
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = context.watch<SettingsService>().settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    final subService = context.watch<SubscriptionService>();
    _onSubscriptionChanged(subService);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Builder(
          builder: (context) {
            Responsive.init(context);
            // P2-4: 横屏时左右分栏
            if (Responsive.isLandscape) {
              return Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      children: [
                        _buildTopBar(isDark, textColor),
                        _buildStatusBar(isDark, textColor, subColor, settings),
                        Expanded(child: SizedBox()),
                      ],
                    ),
                  ),
                  VerticalDivider(
                      width: 1,
                      color:
                          isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
                  Expanded(
                    flex: 7,
                    child: Column(
                      children: [
                        _buildNodeListHeader(textColor, subColor, isDark),
                        Expanded(
                            child: _buildNodeListView(
                                textColor, subColor, isDark)),
                      ],
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                _buildTopBar(isDark, textColor),
                _buildStatusBar(isDark, textColor, subColor, settings),
                Expanded(child: _buildNodeList(textColor, subColor, isDark)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isDark, Color textColor) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.gap(16),
        Responsive.gap(8),
        Responsive.gap(16),
        Responsive.gap(4),
      ),
      child: Row(
        children: [
          Container(
            width: Responsive.wp(32),
            height: Responsive.wp(32),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: [AppTheme.primaryColor, AppTheme.accentColor]),
              borderRadius: BorderRadius.circular(Responsive.radius(8)),
            ),
            child: Icon(Icons.shield_rounded,
                color: Colors.white, size: Responsive.icon(18)),
          ),
          SizedBox(width: Responsive.gap(10)),
          Text('SSRVPN',
              style: TextStyle(
                  fontSize: Responsive.sp(18),
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  letterSpacing: 0.5)),
          const Spacer(),
          if (_isConnected)
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.gap(8), vertical: Responsive.gap(4)),
              decoration: BoxDecoration(
                color: AppTheme.successColor.withValues(alpha: 20 / 255),
                borderRadius: BorderRadius.circular(Responsive.radius(8)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle,
                      size: Responsive.icon(14), color: AppTheme.successColor),
                  SizedBox(width: Responsive.gap(4)),
                  Text('已连接',
                      style: TextStyle(
                          fontSize: Responsive.sp(12),
                          color: AppTheme.successColor,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          SizedBox(width: Responsive.gap(8)),
          GestureDetector(
            onTap: () => _showTutorial(context),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.gap(10), vertical: Responsive.gap(6)),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkCard : AppTheme.lightBg,
                borderRadius: BorderRadius.circular(Responsive.radius(8)),
                border: Border.all(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book_rounded,
                      size: Responsive.icon(14),
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary),
                  SizedBox(width: Responsive.gap(4)),
                  Text('使用教程',
                      style: TextStyle(
                          fontSize: Responsive.sp(12),
                          fontWeight: FontWeight.w500,
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(
      bool isDark, Color textColor, Color subColor, AppSettings settings) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Responsive.gap(16), Responsive.gap(8),
          Responsive.gap(16), Responsive.gap(8)),
      child: AnimatedBuilder(
        animation: _glowController,
        builder: (context, child) {
          final glowIntensity = _isConnected
              ? 0.25 + 0.15 * math.sin(_glowController.value * 2 * math.pi)
              : 0.0;
          final glowColor =
              AppTheme.successColor.withValues(alpha: glowIntensity);
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Responsive.radius(16)),
              boxShadow: _isConnected
                  ? [
                      BoxShadow(
                          color: glowColor, blurRadius: 24, spreadRadius: -2),
                      BoxShadow(
                          color: AppTheme.accentColor
                              .withValues(alpha: glowIntensity * 80 / 255),
                          blurRadius: 40,
                          spreadRadius: -8),
                    ]
                  : null,
            ),
            child: child,
          );
        },
        child: GlassContainer(
          borderRadius: Responsive.radius(16),
          padding: EdgeInsets.symmetric(
              vertical: Responsive.gap(20), horizontal: Responsive.gap(16)),
          child: Column(
            children: [
              Row(
                children: [
                  ConnectionButton(
                    isConnected: _isConnected,
                    isConnecting: _isConnecting,
                    onTap: _handleConnectToggle,
                  ),
                  SizedBox(width: Responsive.gap(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ForceProxyButton(
                            onTap: _showForceProxySitesDialog,
                            enabled: !_isConnecting),
                        SizedBox(height: Responsive.gap(10)),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            _isConnecting
                                ? '正在连接...'
                                : _isConnected
                                    ? '已连接'
                                    : '未连接',
                            key: ValueKey(_isConnecting
                                ? 'c'
                                : _isConnected
                                    ? 'y'
                                    : 'n'),
                            style: TextStyle(
                                fontSize: Responsive.sp(18),
                                fontWeight: FontWeight.w700,
                                color: _isConnected
                                    ? AppTheme.successColor
                                    : textColor),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(height: Responsive.gap(4)),
                        if (_isConnected)
                          Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppTheme.successColor
                                  .withValues(alpha: 15 / 255),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                                '${settings.proxyMode.chineseName} · 端口 ${settings.proxyPort}',
                                style: TextStyle(
                                    fontSize: Responsive.sp(11),
                                    color: subColor,
                                    fontWeight: FontWeight.w500)),
                          ),
                        if (_errorMessage != null) ...[
                          SizedBox(height: 8),
                          Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppTheme.errorColor
                                  .withValues(alpha: 15 / 255),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: AppTheme.errorColor
                                      .withValues(alpha: 40 / 255)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.error_outline,
                                        size: 12, color: AppTheme.errorColor),
                                    SizedBox(width: 6),
                                    Expanded(
                                      child: Text(_errorMessage!,
                                          style: TextStyle(
                                              color: AppTheme.errorColor,
                                              fontSize: Responsive.sp(11))),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 6),
                                Row(
                                  children: [
                                    GestureDetector(
                                      onTap: () => _showLogs(context),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.bug_report,
                                              size: 12,
                                              color: AppTheme.warningColor),
                                          SizedBox(width: 4),
                                          Text('查看日志',
                                              style: TextStyle(
                                                  fontSize: Responsive.sp(10),
                                                  color: AppTheme.warningColor
                                                      .withValues(
                                                          alpha: 200 / 255),
                                                  decoration: TextDecoration
                                                      .underline)),
                                        ],
                                      ),
                                    ),
                                    SizedBox(width: 12),
                                    GestureDetector(
                                      onTap: () => _handleConnectToggle(),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.refresh,
                                              size: 12,
                                              color: AppTheme.primaryColor),
                                          SizedBox(width: 4),
                                          Text('重试',
                                              style: TextStyle(
                                                  fontSize: Responsive.sp(10),
                                                  color: AppTheme.primaryColor
                                                      .withValues(
                                                          alpha: 200 / 255),
                                                  decoration:
                                                      TextDecoration.underline,
                                                  fontWeight: FontWeight.w700)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 14),
              ProxyModeSelector(
                isDark: isDark,
                settings: settings,
                enabled: !_isConnecting,
                onChanged: _handleProxyModeChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNodeList(Color textColor, Color subColor, bool isDark) {
    return Column(
      children: [
        _buildNodeListHeader(textColor, subColor, isDark),
        Expanded(child: _buildNodeListView(textColor, subColor, isDark)),
      ],
    );
  }

  Widget _buildNodeListHeader(Color textColor, Color subColor, bool isDark) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Responsive.gap(16), Responsive.gap(4),
          Responsive.gap(16), Responsive.gap(4)),
      child: Row(
        children: [
          Container(
            width: Responsive.wp(3),
            height: Responsive.hp(14),
            decoration: BoxDecoration(
                color: AppTheme.primaryColor,
                borderRadius: BorderRadius.circular(2)),
          ),
          SizedBox(width: Responsive.gap(8)),
          Text('全部节点',
              style: TextStyle(
                  fontSize: Responsive.sp(15),
                  fontWeight: FontWeight.w700,
                  color: textColor)),
          SizedBox(width: Responsive.gap(6)),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Responsive.gap(7), vertical: Responsive.gap(2)),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 20 / 255),
              borderRadius: BorderRadius.circular(Responsive.radius(8)),
            ),
            child: Text('${_nodes.length}',
                style: TextStyle(
                    fontSize: Responsive.sp(11),
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryColor)),
          ),
          const Spacer(),
          if (_isBatchTesting)
            SizedBox(
              width: Responsive.icon(14),
              height: Responsive.icon(14),
              child: const CircularProgressIndicator(
                  strokeWidth: 2, color: AppTheme.primaryColor),
            )
          else if (_isConnected)
            _SmallButton(
                icon: Icons.speed, label: '测速', onTap: _handleTestAllLatency),
        ],
      ),
    );
  }

  Widget _buildNodeListView(Color textColor, Color subColor, bool isDark) {
    if (_isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: AppTheme.primaryColor),
            ),
            SizedBox(height: 14),
            Text('正在启动VPN核心...',
                style: TextStyle(fontSize: Responsive.sp(13), color: subColor)),
          ],
        ),
      );
    }

    if (_nodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 10 / 255),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.dns_outlined,
                  size: 28,
                  color: AppTheme.primaryColor.withValues(alpha: 100 / 255)),
            ),
            SizedBox(height: 16),
            Text('暂无节点',
                style: TextStyle(
                    fontSize: Responsive.sp(15),
                    fontWeight: FontWeight.w600,
                    color: textColor)),
            SizedBox(height: 6),
            Text('请先在订阅页面添加订阅链接',
                style: TextStyle(fontSize: Responsive.sp(12), color: subColor)),
          ],
        ),
      );
    }

    final sections = HomeNodeController.buildDisplaySections(_nodes);
    return ListView(
      padding: EdgeInsets.fromLTRB(
          12,
          6,
          12,
          MediaQuery.of(context).padding.bottom +
              LiquidGlassNavBar.height +
              20),
      children: [
        for (final section in sections)
          ..._buildNodeSection(section, textColor, subColor, isDark),
      ],
    );
  }

  List<Widget> _buildNodeSection(
    HomeNodeSection section,
    Color textColor,
    Color subColor,
    bool isDark,
  ) {
    if (!section.collapsible) {
      return [
        for (final node in section.nodes)
          _buildNodeTile(node, textColor, subColor, isDark),
      ];
    }

    final title = section.title!;
    final expanded = _expandedSubscriptionGroups.contains(title);
    return [
      _SubscriptionGroupHeader(
        title: title,
        count: section.nodes.length,
        expanded: expanded,
        textColor: textColor,
        subColor: subColor,
        isDark: isDark,
        onTap: () {
          setState(() {
            if (!expanded) {
              _expandedSubscriptionGroups.add(title);
            } else {
              _expandedSubscriptionGroups.remove(title);
            }
          });
        },
      ),
      if (expanded)
        for (final node in section.nodes)
          _buildNodeTile(node, textColor, subColor, isDark),
    ];
  }

  Widget _buildNodeTile(
    ProxyNode node,
    Color textColor,
    Color subColor,
    bool isDark,
  ) {
    final latency = _latencies[node.name] ?? node.latency;
    final isTesting = _testingNodeName == node.name;
    final isSelected = _selectedNode?.name == node.name;
    final isTimeout = latency != null && (latency <= 0 || latency >= 65535);

    return NodeListTile(
      node: node,
      latency: latency,
      isTesting: isTesting,
      isSelected: isSelected,
      isTimeout: isTimeout,
      isConnected: _isConnected,
      onTestLatency: () =>
          _handleTestLatency(node.name, node.server, node.port),
      onTap: () => _handleSelectNode(node),
      onLongPress: () => _editNode(node),
      onEdit: () => _editNode(node),
      textColor: textColor,
      subColor: subColor,
      isDark: isDark,
    );
  }
}

class _SubscriptionGroupHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final Color textColor;
  final Color subColor;
  final bool isDark;
  final VoidCallback onTap;

  const _SubscriptionGroupHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.textColor,
    required this.subColor,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.gap(6)),
      child: InkWell(
        borderRadius: BorderRadius.circular(Responsive.radius(10)),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: Responsive.gap(12),
            vertical: Responsive.gap(10),
          ),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightBg,
            borderRadius: BorderRadius.circular(Responsive.radius(10)),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: Responsive.icon(20),
                color: AppTheme.primaryColor,
              ),
              SizedBox(width: Responsive.gap(8)),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Responsive.sp(13),
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              SizedBox(width: Responsive.gap(8)),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: Responsive.sp(11),
                  fontWeight: FontWeight.w600,
                  color: subColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForceProxyButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool enabled;
  const _ForceProxyButton({required this.onTap, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: Responsive.wp(170)),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: Responsive.gap(8), vertical: Responsive.gap(6)),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor
                  .withValues(alpha: (isDark ? 24 : 16) / 255),
              borderRadius: BorderRadius.circular(Responsive.radius(10)),
              border: Border.all(
                  color: AppTheme.primaryColor
                      .withValues(alpha: (isDark ? 70 : 55) / 255)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_link_rounded,
                    size: Responsive.icon(14), color: AppTheme.primaryColor),
                SizedBox(width: Responsive.gap(4)),
                Flexible(
                  child: Text('添加强制代理网站',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: Responsive.sp(10),
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryColor)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SmallButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppTheme.primaryColor),
            SizedBox(width: 3),
            Text(label,
                style: TextStyle(
                    fontSize: Responsive.sp(11),
                    fontWeight: FontWeight.w500,
                    color: AppTheme.primaryColor)),
          ],
        ),
      ),
    );
  }
}

class _TutorialStepData {
  final String text;
  const _TutorialStepData(this.text);
}

class _TutorialStep extends StatelessWidget {
  final String step;
  final String text;
  const _TutorialStep({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: AppTheme.primaryColor
                .withValues(alpha: (isDark ? 30 : 20) / 255),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(step,
                style: TextStyle(
                    fontSize: Responsive.sp(12),
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryColor)),
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(text,
                style: TextStyle(
                    fontSize: Responsive.sp(14),
                    height: 1.5,
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary)),
          ),
        ),
      ],
    );
  }
}

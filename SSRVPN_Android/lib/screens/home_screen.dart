import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../services/connection_orchestrator.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/connection_button.dart';
import '../widgets/force_proxy_sites_dialog.dart';
import '../widgets/glass_container.dart';
import '../widgets/home_node_list.dart';
import '../widgets/proxy_mode_selector.dart';
import 'home_connection_status_policy.dart';
import 'node_edit_screen.dart';

part 'home_dashboard_part.dart';
part 'home_dialogs_part.dart';
part 'home_connection_actions_part.dart';
part 'home_lifecycle_actions_part.dart';
part 'home_node_actions_part.dart';
part 'home_public_ip_part.dart';

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

  void _updateHomeState(VoidCallback update) => setState(update);

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
  Timer? _latencyBatchTimer;
  Timer? _publicIpTimer;
  Timer? _updateCheckTimer;
  bool _updateCheckInProgress = false;
  int _lastRevision = -1;
  int _publicIpGeneration = 0;
  int _connectionStatusEpoch = 0;
  bool _disposed = false;
  Future<void> _nodeSelectionTail = Future<void>.value();
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

  /// 供外部（app.dart）在页面切换回来时强制刷新节点列表
  void refreshNodes() {
    if (_disposed || !mounted) return;
    final subService = context.read<SubscriptionService>();
    final latestNodes =
        HomeNodeController.runnableNodesFrom(subService.allNodes);
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
    _publicIpTimer?.cancel();
    _updateCheckTimer?.cancel();
    _subscriptionService?.removeListener(_handleSubscriptionServiceChanged);
    _glowController.dispose();
    super.dispose();
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
        publicIpInfo: _publicIpInfo,
        isRefreshingPublicIp: _isRefreshingPublicIp,
        publicIpError: _publicIpError,
        glowAnimation: _glowController,
        onToggleConnection: _handleConnectToggle,
        onShowTutorial: () => _showAndroidHomeTutorialDialog(context),
        onShowForceProxySites: _showForceProxySitesDialog,
        onShowLogs: () => _showAndroidHomeLogsSheet(context),
        onRefreshPublicIp: () => unawaited(_refreshPublicIpInfo()),
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

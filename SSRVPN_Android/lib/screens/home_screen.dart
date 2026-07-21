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
import '../widgets/force_proxy_sites_dialog.dart';
import '../widgets/glass_container.dart';
import 'home_latency_result_guard.dart';
import 'home_connection_status_policy.dart';
import 'node_edit_screen.dart';

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
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void _updateHomeState(VoidCallback update) {
    setState(update);
    _nodeSelectionRefresh.value++;
  }

  List<ProxyNode> _nodes = [];
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isBatchTesting = false;
  String? _errorMessage;
  String? _testingNodeName;
  int _singleLatencyGeneration = 0;
  ProxyNode? _selectedNode;
  PublicIpInfo? _publicIpInfo;
  bool _isRefreshingPublicIp = false;
  String? _publicIpError;

  final HomeLatencyController _latencyController = HomeLatencyController();
  final ValueNotifier<int> _nodeSelectionRefresh = ValueNotifier<int>(0);
  Timer? _latencyBatchTimer;
  int? _latencyBatchGeneration;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      unawaited(_loadInitialData());
    });
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
      _updateHomeState(() {});
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
      _cancelSingleLatencyTest();
      _cancelLatencyBatch();
      _lastRevision = revision;
      _updateHomeState(() {
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
    _cancelSingleLatencyTest();
    _cancelLatencyBatch();
    _publicIpTimer?.cancel();
    _updateCheckTimer?.cancel();
    _subscriptionService?.removeListener(_handleSubscriptionServiceChanged);
    _nodeSelectionRefresh.dispose();
    super.dispose();
  }

  // ── 设置入口已移除，关键设置项融入首页 ──

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = context.watch<SettingsService>().settings;
    final displayNode = _isConnected
        ? HomeNodeController.resolveRuntimeSelectedNodeFrom(
            _nodes,
            _selectedNode?.name,
          )
        : HomeNodeController.resolveDefaultNodeFrom(
            _nodes,
            resolveAndroidPreferredNodeName(
              selectedNodeName: _selectedNode?.name,
              rememberedNodeName: settings.lastSelectedNodeName,
            ),
          );
    final selectedLatency =
        displayNode == null ? null : _latencyController.latencyFor(displayNode);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SsrvpnHomeOverview(
        isConnected: _isConnected,
        isConnecting: _isConnecting,
        selectedNode: displayNode,
        selectedLatency: selectedLatency,
        selectedCountryCode:
            displayNode == null ? null : countryCodeForProxyNode(displayNode),
        errorMessage: _errorMessage,
        publicIpv4: _publicIpInfo?.displayText,
        isRefreshingPublicIp: _isRefreshingPublicIp,
        publicIpError: _publicIpError,
        onToggleConnection: _handleConnectToggle,
        onOpenNodes: _openNodeSelection,
        onShowAbout: () => showSsrvpnAboutDialog(context),
        onShowTutorial: () => _showAndroidHomeTutorialDialog(context),
        onShowLogs: () => _showAndroidHomeLogsSheet(context),
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
                    resolveAndroidPreferredNodeName(
                      selectedNodeName: _selectedNode?.name,
                      rememberedNodeName: settings.lastSelectedNodeName,
                    ),
                  )?.name;
          },
          proxyModeOf: () => context.read<SettingsService>().settings.proxyMode,
          testingNodeNameOf: () => _testingNodeName,
          isBatchTestingOf: () => _isBatchTesting,
          isConnectingOf: () => _isConnecting,
          countryCodeOf: countryCodeForProxyNode,
          latencyOf: _latencyController.latencyFor,
          canSelectNode: (node) =>
              !_isConnected || _latencyController.canSelect(node),
          onClose: () => Navigator.of(routeContext).pop(),
          onRefresh: _loadInitialData,
          onTestAll: _handleTestAllLatency,
          onTestLatency: (node) =>
              _handleTestLatency(node.name, node.server, node.port),
          onSelectNode: _handleSelectNode,
          onProxyModeChanged: (mode) => _handleProxyModeChanged(mode.name),
          onShowForceProxySites: _showForceProxySitesDialog,
          onShowLogs: () => _showAndroidHomeLogsSheet(context),
          onLongPressNode: (node) => unawaited(_editNode(node)),
        ),
      ),
    );
    if (mounted && !_disposed) _updateHomeState(() {});
  }
}

class _TutorialStepData {
  final String text;
  const _TutorialStepData(this.text);
}

import 'ssrvpn_glass_dialog_route.dart';
import 'ssrvpn_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../models/proxy_node.dart';
import '../utils/node_display_policy.dart';
import '../utils/node_country_policy.dart';
import 'country_flag_icon.dart';
import 'ssrvpn_app_surface.dart';
import 'ssrvpn_global_mode_dialog.dart';

part 'ssrvpn_node_selection_controls.dart';
part 'ssrvpn_node_selection_latency.dart';
part 'ssrvpn_node_selection_keyboard.dart';
part 'ssrvpn_node_selection_support_controls.dart';
part 'ssrvpn_node_selection_subscription_filter.dart';
part 'ssrvpn_node_selection_node_card.dart';

typedef SsrvpnNodeAction = Future<void> Function(ProxyNode node);

// Subscription groups are trimmed and empty groups are excluded, so the empty
// string is an unambiguous internal value for the aggregate view.
const _allSubscriptions = '';

class SsrvpnNodeSelectionPage extends StatefulWidget {
  const SsrvpnNodeSelectionPage({
    super.key,
    this.ownerStateListenable,
    required this.nodesOf,
    required this.selectedNodeNameOf,
    required this.proxyModeOf,
    required this.testingNodeNameOf,
    required this.isBatchTestingOf,
    required this.isConnectingOf,
    required this.countryCodeOf,
    required this.latencyOf,
    required this.onClose,
    required this.onRefresh,
    required this.onTestAll,
    this.onTestNodes,
    this.onCancelTest,
    required this.onTestLatency,
    required this.onSelectNode,
    required this.onProxyModeChanged,
    this.enableTunOf,
    this.onEnableTunChanged,
    this.tunLabel,
    this.onShowForceProxySites,
    this.onShowForceDirectSites,
    this.onSecondaryTapDown,
    this.onLongPressNode,
    this.canSelectNode,
  });

  /// Emits when the owner-backed getters may return different values while
  /// this route remains mounted above its owner.
  final Listenable? ownerStateListenable;
  final ValueGetter<List<ProxyNode>> nodesOf;
  final ValueGetter<String?> selectedNodeNameOf;
  final ValueGetter<ProxyMode> proxyModeOf;
  final ValueGetter<bool>? enableTunOf;
  final ValueGetter<String?> testingNodeNameOf;
  final ValueGetter<bool> isBatchTestingOf;
  final ValueGetter<bool> isConnectingOf;
  final String Function(ProxyNode node) countryCodeOf;
  final int? Function(ProxyNode node) latencyOf;
  final VoidCallback onClose;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onTestAll;
  final Future<void> Function(List<ProxyNode> nodes)? onTestNodes;
  final VoidCallback? onCancelTest;
  final SsrvpnNodeAction onTestLatency;
  final SsrvpnNodeAction onSelectNode;
  final Future<void> Function(ProxyMode mode) onProxyModeChanged;
  final Future<void> Function(bool enabled)? onEnableTunChanged;
  final String? tunLabel;
  final VoidCallback? onShowForceProxySites;
  final VoidCallback? onShowForceDirectSites;
  final void Function(ProxyNode node, TapDownDetails details)?
      onSecondaryTapDown;
  final ValueChanged<ProxyNode>? onLongPressNode;
  final bool Function(ProxyNode node)? canSelectNode;

  @override
  State<SsrvpnNodeSelectionPage> createState() =>
      _SsrvpnNodeSelectionPageState();
}

class _SsrvpnNodeSelectionPageState extends State<SsrvpnNodeSelectionPage> {
  late String? _selectedNodeName;
  late ProxyMode _proxyMode;
  late bool? _enableTun;
  String _subscription = _allSubscriptions;
  bool _sortByLatency = false;
  bool _actionBusy = false;
  bool _closeRequested = false;
  void _updateSelectionState(VoidCallback action) => setState(action);

  bool _testingAction = false;
  bool _stopRequested = false;
  bool _selectingTests = false;
  final Set<String> _testSelection = {};

  @override
  void initState() {
    super.initState();
    _syncFromOwner();
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
    widget.ownerStateListenable?.addListener(_handleOwnerStateChanged);
  }

  @override
  void didUpdateWidget(covariant SsrvpnNodeSelectionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.ownerStateListenable,
      widget.ownerStateListenable,
    )) {
      oldWidget.ownerStateListenable?.removeListener(_handleOwnerStateChanged);
      widget.ownerStateListenable?.addListener(_handleOwnerStateChanged);
    }
    _syncFromOwner();
  }

  @override
  void dispose() {
    widget.ownerStateListenable?.removeListener(_handleOwnerStateChanged);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    super.dispose();
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    _requestClose();
    return true;
  }

  void _handleOwnerStateChanged() {
    if (!mounted) return;
    setState(_syncFromOwner);
  }

  void _syncFromOwner() {
    _selectedNodeName = widget.selectedNodeNameOf();
    _proxyMode = widget.proxyModeOf();
    _enableTun = widget.enableTunOf?.call();
  }

  void _requestClose() {
    if (_closeRequested) return;
    _closeRequested = true;
    widget.onClose();
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_actionBusy || widget.isConnectingOf()) return;
    setState(() => _actionBusy = true);
    try {
      await action();
      if (!mounted) return;
      setState(_syncFromOwner);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  List<String> _subscriptionNames(List<ProxyNode> nodes) {
    final names = nodes
        .map((node) => node.group.trim())
        .where((group) => group.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return names;
  }

  List<ProxyNode> _visibleNodes(List<ProxyNode> nodes, String subscription) {
    if (subscription == _allSubscriptions) return nodes;
    return nodes.where((node) => node.group.trim() == subscription).toList();
  }

  @override
  Widget build(BuildContext context) {
    final nodes = widget.nodesOf();
    final groups = _subscriptionNames(nodes);
    final effectiveSubscription =
        _subscription == _allSubscriptions || groups.contains(_subscription)
            ? _subscription
            : _allSubscriptions;
    if (effectiveSubscription != _subscription) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _subscription == _allSubscriptions) return;
        final currentGroups = _subscriptionNames(widget.nodesOf());
        if (!currentGroups.contains(_subscription)) {
          setState(() => _subscription = _allSubscriptions);
        }
      });
    }
    final filteredNodes = _visibleNodes(nodes, effectiveSubscription);
    final visibleNodes =
        _sortByLatency ? _latencySortedNodes(filteredNodes) : filteredNodes;
    final selectedNode = nodes.cast<ProxyNode?>().firstWhere(
          (node) => node?.name == _selectedNodeName,
          orElse: () => null,
        );
    final selectionBusy = _actionBusy || widget.isConnectingOf();
    final batchRunning = _testingAction || widget.isBatchTestingOf();
    final testingBusy = selectionBusy || batchRunning;
    final nodesToTest = _selectingTests
        ? nodes.where((node) => _testSelection.contains(node.name)).toList()
        : filteredNodes;
    final controls = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ModePanel(
          proxyMode: _proxyMode,
          enableTun: _enableTun,
          tunLabel: widget.tunLabel,
          busy: selectionBusy,
          onProxyModeChanged: _changeProxyMode,
          onEnableTunChanged: widget.onEnableTunChanged == null
              ? null
              : (enabled) =>
                  _runAction(() => widget.onEnableTunChanged!(enabled)),
        ),
        if (widget.onShowForceProxySites != null ||
            widget.onShowForceDirectSites != null) ...[
          const SizedBox(height: 10),
          _UtilityActions(
            forceProxyEnabled: !selectionBusy,
            onShowForceProxySites: widget.onShowForceProxySites,
            onShowForceDirectSites: widget.onShowForceDirectSites,
          ),
        ],
        const SizedBox(height: 14),
        _SubscriptionFilter(
          groups: groups,
          value: effectiveSubscription,
          sortByLatency: _sortByLatency,
          onChanged: (value) {
            setState(() => _subscription = value);
          },
          onSortPressed: () {
            setState(() => _sortByLatency = !_sortByLatency);
          },
        ),
        if (widget.onTestNodes != null) ...[
          Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: testingBusy
                      ? null
                      : () => setState(() {
                            _selectingTests = !_selectingTests;
                            _testSelection.clear();
                          }),
                  child: Text(_selectingTests ? '退出多选' : '选择测速节点'),
                ),
                Text(_selectingTests
                    ? '已选 ${nodesToTest.length} 个节点'
                    : '测速范围：当前分组 ${nodesToTest.length} 个节点'),
                if (batchRunning && widget.onCancelTest != null)
                  TextButton.icon(
                    onPressed: _stopRequested ? null : _stopTests,
                    icon: const Icon(Icons.stop_rounded),
                    label: Text(_stopRequested ? '正在结束当前检测…' : '停止测速'),
                  ),
              ]),
          const Text('测速仅检测连接延迟，不代表下载速度或长期稳定性。'),
        ],
        const SizedBox(height: 12),
      ],
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _requestClose,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: SsrvpnUiTokens.background,
          body: SsrvpnAppBackdrop(
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  key: const Key('ssrvpn-node-selection-content'),
                  constraints: const BoxConstraints(
                    maxWidth: SsrvpnUiTokens.pageMaxWidth,
                  ),
                  child: Column(
                    children: [
                      _NodeSelectionHeader(
                        selectedNode: selectedNode,
                        countryCode: selectedNode == null
                            ? 'UN'
                            : widget.countryCodeOf(selectedNode),
                        busy: testingBusy,
                        onClose: _requestClose,
                        onRefresh: () => _runAction(widget.onRefresh),
                        testLabel: _selectingTests ? '测试所选节点延迟' : '测试当前分组延迟',
                        onTestAll: () => _testNodes(nodesToTest),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                          child: CustomScrollView(
                            key: const Key('ssrvpn-node-list'),
                            slivers: [
                              SliverToBoxAdapter(child: controls),
                              if (visibleNodes.isEmpty)
                                const SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: _NodeEmptyState(),
                                )
                              else
                                SliverPadding(
                                  padding: const EdgeInsets.only(bottom: 20),
                                  sliver: SliverList.builder(
                                    itemCount: visibleNodes.length,
                                    itemBuilder: (context, index) => _nodeCard(
                                      visibleNodes[index],
                                      selectionBusy: selectionBusy,
                                      testingBusy: testingBusy,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

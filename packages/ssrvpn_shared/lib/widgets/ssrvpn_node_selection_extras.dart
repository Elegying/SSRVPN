part of 'ssrvpn_node_selection_page.dart';

extension _NodeSelectionExtras on _SsrvpnNodeSelectionPageState {
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
    return nodes
        .where(
          (node) =>
              (subscription == _allSubscriptions ||
                  node.group.trim() == subscription) &&
              NodeSearchPolicy.matches(node, _searchQuery),
        )
        .toList();
  }

  void _initPins() {
    final directory = widget.preferenceDirectory;
    if (directory == null || directory.isEmpty) return;
    final store =
        widget.pinStoreFactory?.call(directory) ?? NodePinStore(directory);
    _pins = store;
    _pinBusy = true;
    store.addListener(() {
      if (mounted) _updateSelectionState(() {});
    });
    store.load().whenComplete(() {
      if (mounted) _updateSelectionState(() => _pinBusy = false);
    }).ignore();
  }

  List<ProxyNode> _pinSorted(List<ProxyNode> nodes) => [
        ...nodes.where((node) => _pins?.contains(node) ?? false),
        ...nodes.where((node) => !(_pins?.contains(node) ?? false)),
      ];
  Future<void> _togglePin(ProxyNode node) async {
    if (_pinBusy || _pins == null) return;
    _updateSelectionState(() => _pinBusy = true);
    try {
      await _pins!.toggle(node);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('置顶保存失败，原顺序已保留，请重试')));
      }
    } finally {
      if (mounted) _updateSelectionState(() => _pinBusy = false);
    }
  }

  Future<void> _openSearch() async {
    if (_searchOpen) return;
    _searchOpen = true;
    final controller = TextEditingController(text: _searchQuery);
    try {
      final result = await showSsrvpnGlassDialog<String>(
        context: context,
        builder: (ctx) => SsrvpnLiquidAlertDialog(
          title: const Text('搜索节点'),
          content: TextField(
            key: const Key('ssrvpn-node-search-input'),
            controller: controller,
            autofocus: true,
            maxLength: NodeSearchPolicy.maxQueryLength,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(hintText: '输入节点名称、订阅或协议关键词'),
            onSubmitted: (value) => dismissSsrvpnDialog(ctx, value),
          ),
          actions: [
            TextButton(
              onPressed: () => dismissSsrvpnDialog(ctx, ''),
              child: const Text('清除搜索'),
            ),
            TextButton(
              onPressed: () => dismissSsrvpnDialog<String>(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => dismissSsrvpnDialog(ctx, controller.text),
              child: const Text('搜索'),
            ),
          ],
        ),
      );
      if (mounted && result != null) {
        _updateSelectionState(() => _searchQuery = result.trim());
      }
    } finally {
      _searchOpen = false;
      controller.dispose();
    }
  }

  Future<void> _openNodeMenu(ProxyNode node, TapDownDetails details) async {
    if (_pinBusy) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showSsrvpnLiquidMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (_pins != null)
          SsrvpnLiquidMenuItem(
            value: 'pin',
            child: Text(_pins!.contains(node) ? '取消置顶' : '置顶'),
          ),
        if (widget.onLongPressNode != null)
          SsrvpnLiquidMenuItem(value: 'edit', child: const Text('编辑')),
      ],
    );
    if (!mounted) return;
    if (selected == 'pin') await _togglePin(node);
    if (selected == 'edit') widget.onLongPressNode?.call(node);
  }

  Widget _pinActions(ProxyNode node, Widget card) {
    if (_pins == null || Theme.of(context).platform != TargetPlatform.android) {
      return card;
    }
    return _SwipePinNode(
      key: ValueKey('pin-swipe-${node.name}'),
      pinned: _pins!.contains(node),
      enabled: !_pinBusy,
      onPin: () => _togglePin(node),
      child: card,
    );
  }
}

class _SwipePinNode extends StatefulWidget {
  const _SwipePinNode({
    super.key,
    required this.pinned,
    required this.enabled,
    required this.onPin,
    required this.child,
  });
  final bool pinned, enabled;
  final Future<void> Function() onPin;
  final Widget child;
  @override
  State<_SwipePinNode> createState() => _SwipePinNodeState();
}

class _SwipePinNodeState extends State<_SwipePinNode> {
  double _offset = 0;
  @override
  Widget build(BuildContext context) => ClipRect(
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 7,
              width: 88,
              child: ExcludeSemantics(
                  excluding: _offset == 0,
                  child: TextButton(
                      onPressed: _offset > 0 && widget.enabled
                          ? () async {
                              setState(() => _offset = 0);
                              await widget.onPin();
                            }
                          : null,
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.push_pin_outlined),
                            Flexible(
                                child: Text(widget.pinned ? '取消置顶' : '置顶',
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis)),
                          ]))),
            ),
            GestureDetector(
              onHorizontalDragUpdate: widget.enabled
                  ? (details) => setState(
                        () =>
                            _offset = (_offset + details.delta.dx).clamp(0, 92),
                      )
                  : null,
              onHorizontalDragCancel: () => setState(() => _offset = 0),
              onHorizontalDragEnd: widget.enabled
                  ? (_) => setState(() => _offset = _offset > 40 ? 92 : 0)
                  : null,
              child: Transform.translate(
                offset: Offset(_offset, 0),
                child: widget.child,
              ),
            ),
          ],
        ),
      );
}

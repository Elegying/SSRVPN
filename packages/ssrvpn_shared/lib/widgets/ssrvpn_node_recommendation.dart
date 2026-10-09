part of 'ssrvpn_node_selection_page.dart';

extension _NodeRecommendation on _SsrvpnNodeSelectionPageState {
  Widget _recommendButton(bool busy, List<ProxyNode> nodes) => TextButton.icon(
        onPressed: busy || nodes.isEmpty ? null : () => _recommend(nodes),
        icon: const Icon(Icons.auto_awesome_rounded),
        label: const Text('一键推荐'),
      );

  Future<void> _recommend(List<ProxyNode> nodes) async {
    if (_testingAction || _actionBusy || widget.isConnectingOf()) return;
    final candidates = List<ProxyNode>.of(nodes);
    final selectedBefore = widget.selectedNodeNameOf();
    final modeBefore = widget.proxyModeOf();
    final actionBefore = _actionEpoch;
    final filterBefore = (_subscription, _searchQuery);
    final testedBefore = {
      for (final node in candidates) node: node.lastLatencyTest
    };
    try {
      if (!await _testNodes(candidates)) return;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('推荐未完成，请稍后重试；当前选择已保留')));
      }
      return;
    }
    if (!mounted ||
        widget.isConnectingOf() ||
        _closeRequested ||
        actionBefore != _actionEpoch ||
        filterBefore != (_subscription, _searchQuery) ||
        selectedBefore != widget.selectedNodeNameOf() ||
        modeBefore != widget.proxyModeOf()) {
      return;
    }
    // Only recommend nodes still present with the same connection identity.
    final current = widget.nodesOf();
    final eligible = candidates
        .where((node) => current.any((item) =>
            item.name == node.name &&
            item.server == node.server &&
            item.port == node.port &&
            item.type == node.type &&
            identical(item, node)))
        .where((node) => widget.canSelectNode?.call(node) ?? true)
        .toList();
    final ranked = _latencySortedNodes(eligible).where((node) {
      if (node.lastLatencyTest == null ||
          identical(node.lastLatencyTest, testedBefore[node])) {
        return false;
      }
      final latency = widget.latencyOf(node);
      return latency != null &&
          latency > 0 &&
          latency < NodeDisplayPolicy.timeoutLatencyMs;
    }).toList();
    if (ranked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂未找到测速成功的候选节点，请检查网络后重试；当前选择已保留')));
      return;
    }
    try {
      await _runAction(() => widget.onSelectNode(ranked.first));
    } catch (_) {
      if (!mounted) return;
      _updateSelectionState(_syncFromOwner);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('推荐选择未完成，请检查当前节点后重试')));
    }
  }
}

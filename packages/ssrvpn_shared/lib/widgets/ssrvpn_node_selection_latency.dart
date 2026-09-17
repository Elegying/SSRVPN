part of 'ssrvpn_node_selection_page.dart';

extension _NodeSelectionLatency on _SsrvpnNodeSelectionPageState {
  Future<void> _testNodes(List<ProxyNode> nodes) async {
    if (_testingAction ||
        _actionBusy ||
        widget.isConnectingOf() ||
        nodes.isEmpty) {
      return;
    }
    _updateSelectionState(() {
      _testingAction = true;
      _stopRequested = false;
    });
    try {
      if (widget.onTestNodes != null) {
        await widget.onTestNodes!(List.unmodifiable(nodes));
      } else {
        await widget.onTestAll();
      }
    } finally {
      if (mounted) {
        _updateSelectionState(() {
          _testingAction = false;
          _stopRequested = false;
          _syncFromOwner();
        });
      }
    }
  }

  void _stopTests() {
    if (_stopRequested) return;
    _updateSelectionState(() => _stopRequested = true);
    widget.onCancelTest?.call();
  }

  List<ProxyNode> _latencySortedNodes(List<ProxyNode> nodes) {
    final indexed = nodes.indexed
        .map((entry) => (entry.$1, entry.$2, widget.latencyOf(entry.$2)))
        .toList(growable: false);
    indexed.sort((left, right) {
      final leftLatency = left.$3;
      final rightLatency = right.$3;
      final leftMeasured = leftLatency != null &&
          leftLatency > 0 &&
          leftLatency < NodeDisplayPolicy.timeoutLatencyMs;
      final rightMeasured = rightLatency != null &&
          rightLatency > 0 &&
          rightLatency < NodeDisplayPolicy.timeoutLatencyMs;
      if (leftMeasured != rightMeasured) return leftMeasured ? -1 : 1;
      if (leftMeasured) {
        final latencyOrder = leftLatency.compareTo(rightLatency!);
        if (latencyOrder != 0) return latencyOrder;
      }
      return left.$1.compareTo(right.$1);
    });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }

  Widget _nodeCard(
    ProxyNode node, {
    required bool selectionBusy,
    required bool testingBusy,
  }) {
    final card = _NodeSelectionCard(
      node: node,
      countryCode: widget.countryCodeOf(node),
      latency: widget.latencyOf(node),
      selected: node.name == _selectedNodeName,
      testing: node.name == widget.testingNodeNameOf(),
      selectionBusy:
          selectionBusy || !(widget.canSelectNode?.call(node) ?? true),
      editBusy: selectionBusy,
      testingBusy: testingBusy,
      onSelect: () => _runAction(() => widget.onSelectNode(node)),
      onTest: () => _runAction(() => widget.onTestLatency(node)),
      onSecondaryTapDown: widget.onSecondaryTapDown == null
          ? null
          : (details) => widget.onSecondaryTapDown!(node, details),
      onLongPress: widget.onLongPressNode == null
          ? null
          : () => widget.onLongPressNode!(node),
    );
    if (!_selectingTests) return card;
    return Row(children: [
      Semantics(
        label: '选择测速节点 ${node.name}',
        child: Checkbox(
            value: _testSelection.contains(node.name),
            onChanged: testingBusy
                ? null
                : (selected) => _updateSelectionState(() {
                      if (selected == true) {
                        _testSelection.add(node.name);
                      } else {
                        _testSelection.remove(node.name);
                      }
                    })),
      ),
      Expanded(child: card),
    ]);
  }
}

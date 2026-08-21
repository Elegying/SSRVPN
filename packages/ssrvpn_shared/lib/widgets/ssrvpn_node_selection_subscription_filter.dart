part of 'ssrvpn_node_selection_page.dart';

class _SubscriptionFilter extends StatelessWidget {
  const _SubscriptionFilter({
    required this.groups,
    required this.value,
    required this.sortByLatency,
    required this.onChanged,
    required this.onSortPressed,
  });

  final List<String> groups;
  final String value;
  final bool sortByLatency;
  final ValueChanged<String> onChanged;
  final VoidCallback onSortPressed;

  Future<void> _openPicker(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
        child: SsrvpnFrostedPanel(
          key: const Key('ssrvpn-subscription-picker-glass'),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: (MediaQuery.sizeOf(dialogContext).height - 72)
                  .clamp(180.0, 520.0),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.rss_feed_rounded,
                      color: SsrvpnUiTokens.primary,
                    ),
                    SizedBox(width: 10),
                    Text(
                      '选择订阅',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: ListView(
                    key: const Key('ssrvpn-subscription-picker-list'),
                    shrinkWrap: true,
                    children: [
                      _SubscriptionPickerItem(
                        label: '全部订阅',
                        value: _allSubscriptions,
                        selected: value == _allSubscriptions,
                      ),
                      ...groups.map(
                        (group) => _SubscriptionPickerItem(
                          label: group,
                          value: group,
                          selected: value == group,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final label = value == _allSubscriptions ? '全部订阅' : value;
    return Container(
      key: ValueKey('ssrvpn-subscription-filter-$value'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: SsrvpnUiTokens.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: SsrvpnUiTokens.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: '选择订阅，当前：$label',
                child: InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(18),
                  ),
                  onTap: () => _openPicker(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 15,
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            Container(width: 1, height: 30, color: SsrvpnUiTokens.border),
            IconButton(
              key: const Key('ssrvpn-node-latency-sort'),
              tooltip: sortByLatency ? '恢复默认节点顺序' : '按延迟从低到高排序',
              onPressed: onSortPressed,
              color: sortByLatency
                  ? SsrvpnUiTokens.primary
                  : SsrvpnUiTokens.textSecondary,
              icon: Icon(
                sortByLatency
                    ? Icons.filter_list_off_rounded
                    : Icons.sort_rounded,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionPickerItem extends StatelessWidget {
  const _SubscriptionPickerItem({
    required this.label,
    required this.value,
    required this.selected,
  });

  final String label;
  final String value;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selected: selected,
        selectedTileColor: SsrvpnUiTokens.primary.withValues(alpha: 0.14),
        leading: Icon(
          selected ? Icons.check_circle_rounded : Icons.circle_outlined,
          color:
              selected ? SsrvpnUiTokens.primary : SsrvpnUiTokens.textTertiary,
          size: 20,
        ),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.pop(context, value),
      ),
    );
  }
}

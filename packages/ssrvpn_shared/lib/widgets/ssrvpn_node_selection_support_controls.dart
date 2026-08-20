part of 'ssrvpn_node_selection_page.dart';

class _NodeSelectionHeader extends StatelessWidget {
  const _NodeSelectionHeader({
    required this.selectedNode,
    required this.countryCode,
    required this.busy,
    required this.onClose,
    required this.onRefresh,
    required this.onTestAll,
  });

  final ProxyNode? selectedNode;
  final String countryCode;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onRefresh;
  final VoidCallback onTestAll;

  @override
  Widget build(BuildContext context) {
    final name = selectedNode == null
        ? '选择服务器'
        : nodeDisplayNameWithoutLeadingFlag(selectedNode!.name);
    final visibleName = compactNodeDisplayName(name);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: [
          Semantics(
            key: const Key('ssrvpn-node-close'),
            container: true,
            label: '关闭服务器选择',
            button: true,
            onTap: onClose,
            excludeSemantics: true,
            child: IconButton(
              tooltip: '关闭服务器选择',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 30),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CountryFlagIcon(countryCode: countryCode, size: 28),
                const SizedBox(width: 10),
                Flexible(
                  child: Tooltip(
                    message: name,
                    child: Text(
                      visibleName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: SsrvpnUiTokens.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新节点',
            onPressed: busy ? null : onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 28),
          ),
          IconButton(
            tooltip: '测试全部节点延迟',
            onPressed: busy ? null : onTestAll,
            icon: const Icon(Icons.bolt_rounded, size: 28),
          ),
        ],
      ),
    );
  }
}

class _UtilityActions extends StatelessWidget {
  const _UtilityActions({
    required this.forceProxyEnabled,
    this.onShowForceProxySites,
    this.onShowLogs,
  });

  final bool forceProxyEnabled;
  final VoidCallback? onShowForceProxySites;
  final VoidCallback? onShowLogs;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 0,
      children: [
        if (onShowForceProxySites != null)
          TextButton.icon(
            onPressed: forceProxyEnabled ? onShowForceProxySites : null,
            icon: const Icon(Icons.add_link_rounded, size: 17),
            label: const Text('强制代理网站'),
          ),
        if (onShowLogs != null)
          TextButton.icon(
            onPressed: onShowLogs,
            icon: const Icon(Icons.receipt_long_rounded, size: 17),
            label: const Text('运行日志'),
          ),
      ],
    );
  }
}

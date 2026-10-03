part of 'ssrvpn_node_selection_page.dart';

class _NodeSelectionHeader extends StatelessWidget {
  const _NodeSelectionHeader({
    required this.selectedNode,
    required this.countryCode,
    required this.busy,
    required this.onClose,
    required this.onRefresh,
    required this.onTestAll,
    required this.testLabel,
  });

  final ProxyNode? selectedNode;
  final String countryCode;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onRefresh;
  final VoidCallback onTestAll;
  final String testLabel;

  @override
  Widget build(BuildContext context) {
    final name = selectedNode == null
        ? '选择服务器'
        : nodeDisplayNameWithoutLeadingFlag(selectedNode!.name);
    final visibleName = compactNodeDisplayName(name);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: [
          Semantics(
            key: Key('ssrvpn-node-close'),
            container: true,
            label: '关闭服务器选择',
            button: true,
            onTap: onClose,
            excludeSemantics: true,
            child: IconButton(
              tooltip: '关闭服务器选择',
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, size: 30),
            ),
          ),
          SizedBox(width: 4),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CountryFlagIcon(countryCode: countryCode, size: 28),
                SizedBox(width: 10),
                Flexible(
                  child: Tooltip(
                    message: name,
                    child: Text(
                      visibleName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: SsrvpnUiTokens.of(context).textPrimary,
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
            icon: Icon(Icons.refresh_rounded, size: 28),
          ),
          IconButton(
            tooltip: testLabel,
            onPressed: busy ? null : onTestAll,
            icon: Icon(Icons.bolt_rounded, size: 28),
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
    this.onShowForceDirectSites,
  });

  final bool forceProxyEnabled;
  final VoidCallback? onShowForceProxySites;
  final VoidCallback? onShowForceDirectSites;

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
            icon: Icon(Icons.add_link_rounded, size: 17),
            label: Text('强制代理网站'),
          ),
        if (onShowForceDirectSites != null)
          TextButton.icon(
            onPressed: forceProxyEnabled ? onShowForceDirectSites : null,
            icon: Icon(Icons.link_off_rounded, size: 17),
            label: Text('强制直连网站'),
          ),
      ],
    );
  }
}

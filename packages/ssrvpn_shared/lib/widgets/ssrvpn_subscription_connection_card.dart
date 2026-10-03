part of 'ssrvpn_subscription_view.dart';

class _SubscriptionConnectionCard extends StatelessWidget {
  const _SubscriptionConnectionCard({
    required this.status,
    required this.currentNodeName,
  });

  final SsrvpnSubscriptionConnectionStatus status;
  final String? currentNodeName;

  @override
  Widget build(BuildContext context) {
    final normalizedNodeName = currentNodeName?.trim();
    final hasCurrentNode =
        status == SsrvpnSubscriptionConnectionStatus.connected &&
            normalizedNodeName != null &&
            normalizedNodeName.isNotEmpty;
    final (label, color, icon) = switch (status) {
      SsrvpnSubscriptionConnectionStatus.disconnected => (
          '未连接',
          SsrvpnUiTokens.of(context).textSecondary,
          Icons.link_off_rounded,
        ),
      SsrvpnSubscriptionConnectionStatus.connecting => (
          '正在连接',
          SsrvpnUiTokens.of(context).warning,
          Icons.sync_rounded,
        ),
      SsrvpnSubscriptionConnectionStatus.connected => (
          '已连接',
          SsrvpnUiTokens.of(context).success,
          Icons.link_rounded,
        ),
    };
    final nodeLabel = hasCurrentNode ? normalizedNodeName : null;
    final statusLabel = '连接状态：$label';
    final semanticsLabel =
        nodeLabel == null ? statusLabel : '$statusLabel。当前节点：$nodeLabel';

    return Semantics(
      key: Key('ssrvpn-subscription-status'),
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: SsrvpnSurfaceCard(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusLabel,
                      style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (nodeLabel != null) ...[
                      SizedBox(height: 3),
                      Row(
                        children: [
                          Text(
                            '当前节点',
                            style: TextStyle(
                              color: SsrvpnUiTokens.of(context).textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Tooltip(
                              message: nodeLabel,
                              child: Text(
                                compactNodeDisplayName(nodeLabel),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: SsrvpnUiTokens.of(context).textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

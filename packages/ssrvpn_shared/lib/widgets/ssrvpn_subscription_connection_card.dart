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
          SsrvpnUiTokens.textSecondary,
          Icons.link_off_rounded,
        ),
      SsrvpnSubscriptionConnectionStatus.connecting => (
          '正在连接',
          SsrvpnUiTokens.warning,
          Icons.sync_rounded,
        ),
      SsrvpnSubscriptionConnectionStatus.connected => (
          '已连接',
          SsrvpnUiTokens.success,
          Icons.link_rounded,
        ),
    };
    final nodeLabel = hasCurrentNode ? normalizedNodeName : null;
    final semanticsLabel =
        nodeLabel == null ? '连接状态：$label' : '连接状态：$label。当前节点：$nodeLabel';

    return Semantics(
      key: const Key('ssrvpn-subscription-status'),
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: SsrvpnSurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (nodeLabel != null) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Text(
                            '当前节点',
                            style: TextStyle(
                              color: SsrvpnUiTokens.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Tooltip(
                              message: nodeLabel,
                              child: Text(
                                compactNodeDisplayName(nodeLabel),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: SsrvpnUiTokens.textPrimary,
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

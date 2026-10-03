part of 'ssrvpn_subscription_view.dart';

class _SubscriptionHeader extends StatelessWidget {
  const _SubscriptionHeader({this.onShowLogs});

  final VoidCallback? onShowLogs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SsrvpnThemeIcon('subscription-header',
            fallback: Icons.rss_feed_rounded, size: 48),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '订阅管理',
                style: TextStyle(
                  color: SsrvpnUiTokens.of(context).textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '支持订阅或节点链接导入',
                style: TextStyle(
                  color: SsrvpnUiTokens.of(context).textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        if (onShowLogs != null) ...[
          SizedBox(width: 10),
          Builder(
            builder: (context) {
              final compact = MediaQuery.sizeOf(context).width < 390 ||
                  MediaQuery.textScalerOf(context).scale(14) > 18;
              if (compact) {
                return TextButton(
                  key: Key('ssrvpn-subscription-logs-button'),
                  onPressed: onShowLogs,
                  style: TextButton.styleFrom(
                    minimumSize: Size(64, 44),
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 70),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('运行日志'),
                    ),
                  ),
                );
              }
              return TextButton.icon(
                key: Key('ssrvpn-subscription-logs-button'),
                onPressed: onShowLogs,
                icon: SsrvpnThemeIcon('logs',
                    fallback: Icons.article_outlined, size: 19),
                label: Text('运行日志'),
              );
            },
          ),
        ],
      ],
    );
  }
}

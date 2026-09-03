part of 'ssrvpn_subscription_view.dart';

class _SubscriptionHeader extends StatelessWidget {
  const _SubscriptionHeader({this.onShowLogs});

  final VoidCallback? onShowLogs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [SsrvpnUiTokens.primaryBlue, SsrvpnUiTokens.accent],
            ),
            borderRadius: BorderRadius.circular(17),
            boxShadow: const [
              BoxShadow(
                color: Color(0x332F6BFF),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child:
              const Icon(Icons.rss_feed_rounded, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 18),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '订阅管理',
                style: TextStyle(
                  color: SsrvpnUiTokens.textPrimary,
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '支持订阅链接与 ssr:// 导入',
                style: TextStyle(
                  color: SsrvpnUiTokens.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        if (onShowLogs != null) ...[
          const SizedBox(width: 10),
          Builder(
            builder: (context) {
              final compact = MediaQuery.sizeOf(context).width < 390 ||
                  MediaQuery.textScalerOf(context).scale(14) > 18;
              if (compact) {
                return Semantics(
                  button: true,
                  label: '打开运行日志',
                  child: ExcludeSemantics(
                    child: IconButton(
                      key: const Key('ssrvpn-subscription-logs-button'),
                      tooltip: '运行日志',
                      onPressed: onShowLogs,
                      icon: const Icon(Icons.article_outlined),
                    ),
                  ),
                );
              }
              return TextButton.icon(
                key: const Key('ssrvpn-subscription-logs-button'),
                onPressed: onShowLogs,
                icon: const Icon(Icons.article_outlined, size: 19),
                label: const Text('运行日志'),
              );
            },
          ),
        ],
      ],
    );
  }
}

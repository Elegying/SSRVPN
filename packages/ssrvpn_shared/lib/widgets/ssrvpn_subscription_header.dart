part of 'ssrvpn_subscription_view.dart';

class _SubscriptionHeader extends StatelessWidget {
  const _SubscriptionHeader();

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
      ],
    );
  }
}

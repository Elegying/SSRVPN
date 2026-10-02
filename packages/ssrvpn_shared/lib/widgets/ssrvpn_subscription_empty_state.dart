part of 'ssrvpn_subscription_view.dart';

class _SubscriptionEmptyState extends StatelessWidget {
  const _SubscriptionEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 54),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.rss_feed_rounded,
              size: 52,
              color: SsrvpnUiTokens.textTertiary,
            ),
            SizedBox(height: 14),
            Text(
              '暂无订阅',
              style: TextStyle(
                color: SsrvpnUiTokens.textSecondary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 5),
            Text(
              '在上方粘贴订阅链接开始使用',
              style: TextStyle(color: SsrvpnUiTokens.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

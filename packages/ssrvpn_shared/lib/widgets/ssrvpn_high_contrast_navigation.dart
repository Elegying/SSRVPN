part of 'ssrvpn_app_surface.dart';

class _PlainNavigation extends StatelessWidget {
  const _PlainNavigation({required this.currentIndex, required this.onTap});
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final content = _navigationContent(context);
    if (SsrvpnTheme.of(context).isIllustrated &&
        !MediaQuery.highContrastOf(context)) {
      return SsrvpnSurfaceCard(
          key: const Key('ssrvpn-bottom-navigation'),
          padding: EdgeInsets.zero,
          radius: 24,
          child: content);
    }
    return DecoratedBox(
        key: Key('ssrvpn-bottom-navigation'),
        decoration: SsrvpnTheme.of(context).isSoft &&
                !MediaQuery.highContrastOf(context)
            ? ssrvpnSoftDecoration(radius: 30)
            : BoxDecoration(
                color: MediaQuery.highContrastOf(context) ||
                        ssrvpnGlassDisabled(context)
                    ? Theme.of(context).colorScheme.surface
                    : SsrvpnUiTokens.of(context).surface.withValues(alpha: .4),
                borderRadius: BorderRadius.circular(28),
                border: SsrvpnTheme.of(context).isSoft &&
                        !MediaQuery.highContrastOf(context)
                    ? null
                    : Border.all(
                        color: MediaQuery.highContrastOf(context)
                            ? Theme.of(context).colorScheme.onSurface
                            : SsrvpnUiTokens.of(context).border,
                        width: MediaQuery.highContrastOf(context) ? 2 : 1),
              ),
        child: content);
  }

  Widget _navigationContent(BuildContext context) => Padding(
        padding: EdgeInsets.all(SsrvpnTheme.of(context).isSoft ? 10 : 4),
        child: SizedBox(
          height: SsrvpnTheme.of(context).isSoft
              ? 76
              : SsrvpnTheme.of(context).variant == AppThemeVariant.cloud
                  ? 80
                  : 72,
          child: Row(
              crossAxisAlignment: SsrvpnTheme.of(context).isSoft
                  ? CrossAxisAlignment.stretch
                  : CrossAxisAlignment.center,
              children: [
                Expanded(
                    child: SsrvpnNavigationDestination(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  label: '主页',
                  selected: currentIndex == 0,
                  onTap: () => onTap(0),
                )),
                Expanded(
                    child: SsrvpnNavigationDestination(
                  icon: Icons.rss_feed_outlined,
                  selectedIcon: Icons.rss_feed_rounded,
                  label: '订阅',
                  selected: currentIndex == 1,
                  onTap: () => onTap(1),
                )),
                Expanded(
                    child: SsrvpnNavigationDestination(
                        icon: Icons.settings_outlined,
                        selectedIcon: Icons.settings_rounded,
                        label: '设置',
                        selected: currentIndex == 2,
                        onTap: () => onTap(2))),
              ]),
        ),
      );
}

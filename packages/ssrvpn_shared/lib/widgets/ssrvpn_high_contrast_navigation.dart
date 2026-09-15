part of 'ssrvpn_app_surface.dart';

class _PlainNavigation extends StatelessWidget {
  const _PlainNavigation({required this.currentIndex, required this.onTap});
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        key: const Key('ssrvpn-bottom-navigation'),
        decoration: BoxDecoration(
          color:
              MediaQuery.highContrastOf(context) || ssrvpnGlassDisabled(context)
                  ? Theme.of(context).colorScheme.surface
                  : SsrvpnUiTokens.surface.withValues(alpha: .4),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
              color: MediaQuery.highContrastOf(context)
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.white.withValues(alpha: .18),
              width: MediaQuery.highContrastOf(context) ? 2 : 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            height: 64,
            child: Row(children: [
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
        ),
      );
}

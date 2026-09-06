part of 'ssrvpn_home_overview.dart';

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.compact,
    required this.onShowAbout,
    required this.onShowTutorial,
  });

  final bool compact;
  final VoidCallback onShowAbout;
  final VoidCallback onShowTutorial;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final actionWidth = (constraints.maxWidth * .24).clamp(48.0, 92.0);
        final style = TextButton.styleFrom(
            foregroundColor: SsrvpnUiTokens.textSecondary,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(48, 48));
        return Row(children: [
          SizedBox(
              width: actionWidth,
              child: Tooltip(
                  message: '关于',
                  child: TextButton(
                      key: const Key('ssrvpn-about-button'),
                      onPressed: onShowAbout,
                      style: style,
                      child: const SsrvpnHomeText('关于',
                          textAlign: TextAlign.center, maxFontSize: 20)))),
          Expanded(
              child: SsrvpnHomeText('SSRVPN',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: SsrvpnUiTokens.textPrimary,
                      fontSize: compact ? 29 : 34,
                      fontWeight: FontWeight.w400),
                  minFontSize: 20)),
          SizedBox(
              width: actionWidth,
              child: Tooltip(
                  message: '使用教程',
                  child: TextButton(
                      key: const Key('ssrvpn-tutorial-button'),
                      onPressed: onShowTutorial,
                      style: style,
                      child: const SsrvpnHomeText('使用教程',
                          textAlign: TextAlign.center, maxFontSize: 20)))),
        ]);
      });
}

class _ConnectionStatusPill extends StatelessWidget {
  const _ConnectionStatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      key: const Key('home-connection-status'),
      label: '连接状态：$label',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: SsrvpnUiTokens.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Flexible(
                  child: SsrvpnHomeText(
                label,
                maxFontSize: 12,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              )),
            ],
          ),
        ),
      ),
    );
  }
}

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
            foregroundColor: SsrvpnUiTokens.of(context).textSecondary,
            padding: EdgeInsets.symmetric(horizontal: 4),
            minimumSize: Size(48, 48));
        return Row(children: [
          SizedBox(
              width: actionWidth,
              child: Tooltip(
                  message: '关于',
                  child: TextButton(
                      key: Key('ssrvpn-about-button'),
                      onPressed: onShowAbout,
                      style: style,
                      child: SsrvpnHomeText('关于',
                          textAlign: TextAlign.center, maxFontSize: 20)))),
          Expanded(
              child: SsrvpnHomeText('SSRVPN',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: SsrvpnUiTokens.of(context).textPrimary,
                      fontSize: compact ? 29 : 34,
                      fontWeight: SsrvpnTheme.of(context).isDefault
                          ? FontWeight.w400
                          : FontWeight.w700),
                  minFontSize: 20)),
          SizedBox(
              width: actionWidth,
              child: Tooltip(
                  message: '使用教程',
                  child: TextButton(
                      key: Key('ssrvpn-tutorial-button'),
                      onPressed: onShowTutorial,
                      style: style,
                      child: SsrvpnHomeText('使用教程',
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
      key: Key('home-connection-status'),
      label: '连接状态：$label',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: SsrvpnUiTokens.of(context).surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: 8),
              Flexible(
                  // Let the actual CJK fallback font define its line box.
                  // A forced Latin strut can misalign Chinese glyphs on Windows.
                  child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                textScaler: TextScaler.noScaling,
                textHeightBehavior: TextHeightBehavior(
                    leadingDistribution: TextLeadingDistribution.even),
                style: TextStyle(
                  height: 1.2,
                  leadingDistribution: TextLeadingDistribution.even,
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

extension _HomeStatus on _HomeOverviewState {
  String get _statusText {
    if (widget.isConnecting) return widget.isConnected ? '正在断开' : '正在连接';
    if (widget.errorMessage != null) return '连接异常';
    if (widget.isConnected && widget.connectionNotice != null) {
      return '已连接（有提醒）';
    }
    if (widget.isConnected) return '已连接';
    return '未连接';
  }

  Color get _statusColor {
    if (widget.isConnecting) return SsrvpnUiTokens.of(context).warning;
    if (widget.errorMessage != null) return SsrvpnUiTokens.of(context).error;
    if (widget.isConnected && widget.connectionNotice != null) {
      return SsrvpnUiTokens.of(context).warning;
    }
    if (widget.isConnected) return SsrvpnUiTokens.of(context).success;
    return SsrvpnUiTokens.of(context).textSecondary;
  }
}

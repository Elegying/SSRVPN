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
  Widget build(BuildContext context) {
    final horizontalPadding = compact ? 4.0 : 10.0;
    final actionStyle = TextButton.styleFrom(
      foregroundColor: SsrvpnUiTokens.textSecondary,
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 8),
      minimumSize: const Size(48, 48),
    );
    final aboutAction = Tooltip(
      message: '关于',
      child: TextButton(
        key: const Key('ssrvpn-about-button'),
        onPressed: onShowAbout,
        style: actionStyle,
        child: const Text('关于'),
      ),
    );
    final tutorialAction = Tooltip(
      message: '使用教程',
      child: TextButton(
        key: const Key('ssrvpn-tutorial-button'),
        onPressed: onShowTutorial,
        style: actionStyle,
        child: const Text('使用教程'),
      ),
    );
    final titleStyle = TextStyle(
      color: SsrvpnUiTokens.textPrimary,
      fontSize: compact ? 29 : 34,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.4,
    );
    final title = Text('SSRVPN', style: titleStyle);
    final textScaler = MediaQuery.textScalerOf(context);
    Size measure(String value, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textScaler: textScaler,
        textDirection: Directionality.of(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      return painter.size;
    }

    const actionTextStyle = TextStyle(fontSize: 14);
    final aboutSize = measure('关于', actionTextStyle);
    final tutorialSize = measure('使用教程', actionTextStyle);
    final titleSize = measure('SSRVPN', titleStyle);
    final aboutWidth = aboutSize.width + horizontalPadding * 2 > 48
        ? aboutSize.width + horizontalPadding * 2
        : 48.0;
    final tutorialWidth = tutorialSize.width + horizontalPadding * 2 > 48
        ? tutorialSize.width + horizontalPadding * 2
        : 48.0;
    final sideWidth = aboutWidth > tutorialWidth ? aboutWidth : tutorialWidth;

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final actionsFit =
            aboutWidth + tutorialWidth + gap <= constraints.maxWidth;
        final actions = actionsFit
            ? Row(
                children: [
                  Align(alignment: Alignment.centerLeft, child: aboutAction),
                  const Spacer(),
                  Align(
                      alignment: Alignment.centerRight, child: tutorialAction),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(alignment: Alignment.centerLeft, child: aboutAction),
                  Align(
                      alignment: Alignment.centerRight, child: tutorialAction),
                ],
              );
        final titleFitsBetweenActions =
            titleSize.width + sideWidth * 2 + gap * 2 <= constraints.maxWidth;
        if (!titleFitsBetweenActions) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [title, const SizedBox(height: 2), actions],
          );
        }
        final measuredHeight = titleSize.height > 48 ? titleSize.height : 48.0;
        return SizedBox(
          height: measuredHeight > 54 ? measuredHeight : 54,
          child: Row(
            children: [
              SizedBox(
                width: sideWidth,
                child:
                    Align(alignment: Alignment.centerLeft, child: aboutAction),
              ),
              const SizedBox(width: gap),
              Expanded(child: Center(child: title)),
              const SizedBox(width: gap),
              SizedBox(
                width: sideWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: tutorialAction,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

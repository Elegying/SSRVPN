part of 'home_screen.dart';

class _AndroidTutorialStep extends StatelessWidget {
  final String step;
  final String text;

  const _AndroidTutorialStep({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Color.lerp(colors.primary, Colors.black, 0.04),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              step,
              style: TextStyle(
                fontSize: Responsive.sp(12),
                fontWeight: FontWeight.w700,
                color: colors.onPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              text,
              style: TextStyle(
                fontSize: Responsive.sp(14),
                height: 1.5,
                color: isDark
                    ? AppTheme.darkTextPrimary
                    : AppTheme.lightTextPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

void _showAndroidHomeTutorialDialog(BuildContext context) {
  showSsrvpnInfoDialog(
    context,
    panelKey: const Key('ssrvpn-tutorial-glass'),
    scrollKey: const Key('android-home-tutorial-scroll'),
    icon: Icons.menu_book_rounded,
    title: '使用教程',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _homeTutorialSteps.length; i++) ...[
          _AndroidTutorialStep(
            step: '${i + 1}',
            text: _homeTutorialSteps[i].text,
          ),
          if (i != _homeTutorialSteps.length - 1) const SizedBox(height: 12),
        ],
      ],
    ),
  );
}

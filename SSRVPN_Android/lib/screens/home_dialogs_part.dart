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

void _showAndroidHomeLogsSheet(BuildContext context) {
  final clashService = context.read<ClashService>();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      height: MediaQuery.of(ctx).size.height * 0.7,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1018),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(color: AppTheme.darkBorder),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.darkBorder)),
            ),
            child: Row(
              children: [
                Icon(Icons.bug_report, size: 18, color: AppTheme.warningColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '诊断与运行日志',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: Responsive.sp(16),
                      fontWeight: FontWeight.w600,
                      color: AppTheme.darkTextPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭诊断中心',
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: AppTheme.darkTextSecondary,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: AppDiagnosticsView(
                runDiagnostics: clashService.runDiagnostics,
                loadHistory: clashService.loadDiagnosticHistory,
                repair: clashService.repairDiagnosticIssue,
                onMessage: (message) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                      content: Text(message),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

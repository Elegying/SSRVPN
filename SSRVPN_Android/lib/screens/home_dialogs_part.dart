part of 'home_screen.dart';

class _AndroidTutorialStep extends StatelessWidget {
  final String step;
  final String text;

  const _AndroidTutorialStep({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(
              alpha: (isDark ? 30 : 20) / 255,
            ),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              step,
              style: TextStyle(
                fontSize: Responsive.sp(12),
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryColor,
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
  final isDark = Theme.of(context).brightness == Brightness.dark;
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: GlassContainer(
        borderRadius: 16,
        enablePress: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(ctx).size.width * 0.88,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            AppTheme.primaryColor,
                            AppTheme.accentColor,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.menu_book_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '使用教程',
                      style: TextStyle(
                        fontSize: Responsive.sp(18),
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.lightTextPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                for (var i = 0; i < _homeTutorialSteps.length; i++) ...[
                  _AndroidTutorialStep(
                    step: '${i + 1}',
                    text: _homeTutorialSteps[i].text,
                  ),
                  if (i != _homeTutorialSteps.length - 1)
                    const SizedBox(height: 12),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      backgroundColor: AppTheme.primaryColor.withValues(
                        alpha: (isDark ? 25 : 15) / 255,
                      ),
                    ),
                    child: Text(
                      '知道了',
                      style: TextStyle(
                        fontSize: Responsive.sp(14),
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void _showAndroidHomeLogsSheet(BuildContext context) {
  final clashService = context.read<ClashService>();
  showModalBottomSheet(
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
                Text(
                  '诊断与运行日志',
                  style: TextStyle(
                    fontSize: Responsive.sp(16),
                    fontWeight: FontWeight.w600,
                    color: AppTheme.darkTextPrimary,
                  ),
                ),
                const Spacer(),
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

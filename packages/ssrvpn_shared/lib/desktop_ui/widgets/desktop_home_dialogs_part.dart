part of desktop_home_screen;

class _DesktopTutorialStep extends StatelessWidget {
  final String step;
  final String text;

  const _DesktopTutorialStep({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: (isDark ? 30 : 20) / 255),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              step,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.primary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

void _showDesktopHomeTutorialDialog(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final isMacOS = desktopPlatformLabel == 'MacOS';
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: GlassContainer(
        borderRadius: 16,
        enablePress: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: (MediaQuery.of(ctx).size.width * 0.88)
                .clamp(280.0, 420.0)
                .toDouble(),
            maxHeight: (MediaQuery.of(ctx).size.height -
                    MediaQuery.of(ctx).viewInsets.vertical -
                    48)
                .clamp(160.0, double.infinity)
                .toDouble(),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    key: const Key('desktop-home-tutorial-scroll'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                AppTheme.primary,
                                AppTheme.accentColor,
                              ],
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.menu_book_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '使用教程',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.textPrimary
                                : AppTheme.lightTextPrimary,
                          ),
                        ),
                        const SizedBox(height: 18),
                        const _DesktopTutorialStep(
                          step: '1',
                          text: '进入订阅页面，粘贴 SSR 代码或订阅链接',
                        ),
                        const SizedBox(height: 12),
                        const _DesktopTutorialStep(
                          step: '2',
                          text: '点击添加后刷新订阅，等待节点加载完成',
                        ),
                        const SizedBox(height: 12),
                        const _DesktopTutorialStep(
                          step: '3',
                          text: '回到首页，选择节点后点击连接按钮',
                        ),
                        const SizedBox(height: 12),
                        _DesktopTutorialStep(
                          step: '4',
                          text: isMacOS
                              ? 'macOS 系统代理无需授权；TUN 模式每次连接都由系统请求管理员授权'
                              : '系统代理无需管理员权限，TUN 模式需管理员权限',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      backgroundColor: AppTheme.primary.withValues(
                        alpha: (isDark ? 25 : 15) / 255,
                      ),
                    ),
                    child: const Text(
                      '知道了',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primary,
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

void _showDesktopHomeLogsDialog(BuildContext context) {
  final clashService = context.read<ClashService>();
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF0E1018),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.88,
        ),
        child: Container(
          width: 640,
          height: 560,
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.bug_report,
                    size: 18,
                    color: AppTheme.warning,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '诊断与运行日志',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭诊断中心',
                    icon: const Icon(
                      Icons.close,
                      size: 18,
                      color: AppTheme.textSecondary,
                    ),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: AppTheme.border),
              Expanded(
                child: AppDiagnosticsView(
                  runDiagnostics: clashService.runDiagnostics,
                  repair: clashService.repairDiagnosticIssue,
                  onMessage: (message) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        content: Text(message),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

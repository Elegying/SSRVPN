part of desktop_home_screen;

class _DesktopTutorialStep extends StatelessWidget {
  final String step;
  final String text;

  const _DesktopTutorialStep({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: Color.lerp(colors.primary, Colors.black, 0.04),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              step,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colors.onPrimary,
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
  final isMacOS = desktopPlatformLabel == 'MacOS';
  showSsrvpnInfoDialog(
    context,
    panelKey: const Key('ssrvpn-tutorial-glass'),
    scrollKey: const Key('desktop-home-tutorial-scroll'),
    icon: Icons.menu_book_rounded,
    title: '使用教程',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
              : '客户端启动时请求管理员授权；授权后系统代理与 TUN 均可直接使用和切换',
        ),
      ],
    ),
  );
}

void _showDesktopHomeLogsDialog(BuildContext context) {
  final clashService = context.read<ClashService>();
  showSsrvpnDiagnosticsDialog(
    context,
    runDiagnostics: clashService.runDiagnostics,
    loadHistory: clashService.loadDiagnosticHistory,
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
  );
}

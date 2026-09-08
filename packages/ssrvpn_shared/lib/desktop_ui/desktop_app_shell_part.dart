part of desktop_app;

class _DesktopAppShell extends StatelessWidget {
  const _DesktopAppShell({
    required this.safeMode,
    required this.startupFailureMessages,
    required this.runtimeNotice,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool safeMode;
  final List<String> startupFailureMessages;
  final RuntimeNotice? runtimeNotice;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  Future<void> _openAvailableUpdate(
    BuildContext context,
    AppUpdateInfo update,
  ) {
    return UpdateService.showUpdateDialog(
      context,
      latestVersion: update.version,
      currentVersion: UpdateService.appVersion,
      downloadUrl: update.downloadUrl,
      changelog: update.changelog,
      sha256: update.sha256,
      fallbackDownloadUrl: update.fallbackDownloadUrl,
      prepareForInstall: () => _prepareForUpdateInstall(context),
    );
  }

  Future<bool> _prepareForUpdateInstall(BuildContext context) async {
    if (!context.mounted) return false;
    final core = context.read<clash.ClashService>();
    var stopped = false;
    try {
      stopped = await core.prepareForUpdateInstall();
    } catch (error, stack) {
      StartupLogger.error('更新前安全断开失败', error, stack);
    }

    if (!stopped && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('更新前无法安全断开连接，已阻止打开安装包。请先手动断开后重试'),
        ),
      );
    }
    return stopped;
  }

  @override
  Widget build(BuildContext context) {
    final availableUpdate =
        context.watch<UpdateAvailabilityController>().availableUpdate;
    final (runtimeNoticeIcon, runtimeNoticeColor, runtimeNoticeTitle) =
        switch (runtimeNotice?.level) {
      RuntimeNoticeLevel.success => (
          Icons.check_circle_outline,
          AppTheme.success,
          '操作已完成',
        ),
      RuntimeNoticeLevel.progress => (
          Icons.sync_outlined,
          AppTheme.primary,
          '正在处理',
        ),
      RuntimeNoticeLevel.warning => (
          Icons.warning_amber_rounded,
          AppTheme.warning,
          '需要注意',
        ),
      RuntimeNoticeLevel.error || null => (
          Icons.error_outline,
          AppTheme.error,
          '操作未完成',
        ),
    };
    final statusBanners = <Widget>[
      if (safeMode)
        const SsrvpnHomeNotice(
          icon: Icons.health_and_safety_outlined,
          color: AppTheme.warning,
          title: '安全模式已启用',
          message: '托盘、旧窗口位置和 Mihomo 自动初始化已跳过。',
        ),
      if (startupFailureMessages.isNotEmpty)
        SsrvpnHomeNotice(
          icon: Icons.error_outline,
          color: AppTheme.error,
          title: '部分启动步骤失败',
          message: startupFailureMessages.join('\n'),
        ),
      if (runtimeNotice != null)
        SsrvpnHomeNotice(
          icon: runtimeNoticeIcon,
          color: runtimeNoticeColor,
          title: runtimeNoticeTitle,
          message: runtimeNotice!.message,
        ),
    ];
    return Scaffold(
      resizeToAvoidBottomInset: currentIndex != 0,
      backgroundColor: Colors.transparent,
      body: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: SsrvpnAppBackdrop(
          child: SsrvpnHomeShell(
            notices: statusBanners,
            body: _PageStack(currentIndex: currentIndex),
            navigation: SsrvpnBottomNavigation(
              currentIndex: currentIndex,
              version: AppConstants.appVersion,
              availableVersion: availableUpdate?.version,
              onUpdateTap: availableUpdate == null
                  ? null
                  : () =>
                      unawaited(_openAvailableUpdate(context, availableUpdate)),
              onTap: onIndexChanged,
            ),
          ),
        ),
      ),
    );
  }
}

class _PageStack extends StatelessWidget {
  const _PageStack({required this.currentIndex});

  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: currentIndex,
      children: [
        HomeScreen(active: currentIndex == 0),
        const SubscriptionScreen(),
      ],
    );
  }
}

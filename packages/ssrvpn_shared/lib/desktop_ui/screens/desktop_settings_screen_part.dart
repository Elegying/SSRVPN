part of desktop_settings_screen;

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _applyNetworkSetting(
    BuildContext context,
    Future<void> Function(SettingsService settings) update,
  ) async {
    final clash = context.read<ClashService>();
    final settings = context.read<SettingsService>();
    final wasRunning = clash.isRunning;
    if (wasRunning) await clash.stop();
    await update(settings);
    clash.updateSettings(settings.settings);

    if (wasRunning && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
            content: Text('网络设置已更新，请重新连接')),
      );
    }
  }

  Future<void> _resetAppData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置应用数据'),
        content: const Text('将清空设置、订阅缓存、窗口位置和生成的核心配置。此操作不会删除程序文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final clash = context.read<ClashService>();
    final settings = context.read<SettingsService>();
    final subscriptions = context.read<SubscriptionService>();

    await clash.stop();
    await subscriptions.resetLocalData();
    await settings.resetAppData();
    await WindowStateStore.clear();
    clash.updateSettings(settings.settings);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('应用数据已重置'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<SettingsService>();
    final settings = service.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subtitleColor =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.primary, AppTheme.accentColor],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.settings_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '设置',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: titleColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            GlassContainer(
              borderRadius: 18,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '代理模式',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '切换模式会断开当前连接，重新连接后生效',
                    style: TextStyle(fontSize: 12, color: subtitleColor),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ProxyMode>(
                      segments: ProxyMode.values
                          .map(
                            (mode) => ButtonSegment(
                              value: mode,
                              label:
                                  Text(mode.chineseName.replaceAll('模式', '')),
                            ),
                          )
                          .toList(),
                      selected: {settings.proxyMode},
                      onSelectionChanged: (selection) {
                        _applyNetworkSetting(
                          context,
                          (service) => service.updateProxyMode(selection.first),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'TUN 模式',
                      style: TextStyle(color: titleColor),
                    ),
                    subtitle: Text(
                      '代理所有流量，需要以管理员身份运行',
                      style: TextStyle(fontSize: 12, color: subtitleColor),
                    ),
                    value: settings.enableTun,
                    onChanged: (value) {
                      _applyNetworkSetting(
                        context,
                        (service) => service.updateEnableTun(value),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassContainer(
              borderRadius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '最小化到系统托盘',
                      style: TextStyle(color: titleColor),
                    ),
                    subtitle: Text(
                      '最小化或关闭窗口时保持后台运行',
                      style: TextStyle(fontSize: 12, color: subtitleColor),
                    ),
                    value: settings.minimizeToTray,
                    onChanged: service.updateMinimizeToTray,
                  ),
                  Divider(
                    height: 1,
                    color: isDark ? AppTheme.border : AppTheme.lightBorder,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '深色模式',
                      style: TextStyle(color: titleColor),
                    ),
                    value: settings.darkMode,
                    onChanged: service.updateDarkMode,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassContainer(
              borderRadius: 18,
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(
                    Icons.restart_alt_rounded,
                    color: AppTheme.warning,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '重置应用数据',
                      style: TextStyle(
                        color: titleColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _resetAppData(context),
                    child: const Text('重置'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'SSRVPN ${UpdateService.appVersion}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: subtitleColor),
            ),
          ],
        ),
      ),
    );
  }
}

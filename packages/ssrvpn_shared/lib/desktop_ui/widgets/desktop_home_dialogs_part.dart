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
        SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: 3),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: isDark
                    ? SsrvpnTheme.of(context).textPrimary
                    : SsrvpnTheme.of(context).textPrimary,
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
    panelKey: Key('ssrvpn-tutorial-glass'),
    scrollKey: Key('desktop-home-tutorial-scroll'),
    icon: Icons.menu_book_rounded,
    title: '使用教程',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _DesktopTutorialStep(
          step: '1',
          text: '进入订阅页面，粘贴节点链接或订阅链接',
        ),
        SizedBox(height: 12),
        const _DesktopTutorialStep(
          step: '2',
          text: '点击添加后刷新订阅，等待节点加载完成',
        ),
        SizedBox(height: 12),
        const _DesktopTutorialStep(
          step: '3',
          text: '回到首页，选择节点后点击连接按钮',
        ),
        SizedBox(height: 12),
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
          margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
          content: Text(message),
        ),
      );
    },
  );
}

extension _DesktopHomeNodeMenu on _HomeScreenState {
  Future<void> _showNodeContextMenu(
    ProxyNode node,
    TapDownDetails details,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlayRect = Offset.zero & overlay.size;
    final selected = await showSsrvpnLiquidMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          details.globalPosition & Size(1, 1), overlayRect),
      items: [
        SsrvpnLiquidMenuItem<String>(
          value: 'edit',
          child: Row(children: [
            Icon(Icons.edit_outlined, size: 18),
            SizedBox(width: 10),
            Text('编辑'),
          ]),
        ),
      ],
    );
    if (selected != 'edit' || !mounted) return;
    await Navigator.of(
      context,
    ).push<bool>(
        SsrvpnGlassPageRoute(builder: (_) => NodeEditScreen(node: node)));
  }
}

extension _DesktopHomeRoutingDialogs on _HomeScreenState {
  Future<void> _showRoutingSitesDialog({required bool forceDirect}) async {
    final settings = context.read<SettingsService>().settings;
    final savedSites = forceDirect
        ? AppSettings.normalizeForceDirectSites(settings.forceDirectSites)
        : AppSettings.normalizeForceProxySites(settings.forceProxySites);
    final sites = await _DesktopForceProxySitesDialog.show(
      context,
      savedSites: savedSites,
      forceDirect: forceDirect,
    );
    if (sites == null || !_canUpdateUi) return;
    try {
      await _applyRoutingSites(sites, forceDirect: forceDirect);
    } catch (error) {
      AppLogger.warning(
        'RoutingSites',
        '保存${forceDirect ? '强制直连' : '强制代理'}网站失败: $error',
      );
      if (!_canUpdateUi) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${forceDirect ? '强制直连' : '强制代理'}网站保存失败，请重试'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _applyRoutingSites(
    List<String> sites, {
    required bool forceDirect,
  }) async {
    final settingsService = context.read<SettingsService>();
    final clashService = context.read<ClashService>();
    if (forceDirect) {
      await settingsService.updateForceDirectSites(sites);
    } else {
      await settingsService.updateForceProxySites(sites);
    }
    clashService.updateLiveSettings(settingsService.settings);

    final shouldReload = _isConnected && !_isConnecting;
    bool? reloadSucceeded;
    if (shouldReload) {
      reloadSucceeded = await _reloadConfig();
    }
    if (!_canUpdateUi) return;

    ScaffoldMessenger.of(context).showSnackBar(
      ssrvpnSnackBar(
        content: Text(
          reloadSucceeded != null
              ? reloadSucceeded
                  ? '${forceDirect ? '强制直连' : '强制代理'}网站已实时生效'
                  : '${forceDirect ? '强制直连' : '强制代理'}网站已保存，当前连接重载失败，请重新连接'
              : '${forceDirect ? '强制直连' : '强制代理'}网站已保存',
        ),
        backgroundColor:
            reloadSucceeded == false ? SsrvpnTheme.of(context).warning : null,
        duration: Duration(seconds: 2),
      ),
    );
  }
}

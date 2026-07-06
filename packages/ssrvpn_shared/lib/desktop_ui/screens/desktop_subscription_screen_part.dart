part of desktop_subscription_screen;

/// 订阅管理页面 - 桌面优化
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final _urlController = TextEditingController();
  bool _isAdding = false;
  bool _isRefreshing = false;
  String? _refreshResult;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addSubscription() async {
    setState(() => _isAdding = true);
    final controller = _subscriptionController(
      context.read<SubscriptionService>(),
    );
    final result = await controller.addSubscription(_urlController.text);
    if (!mounted) return;

    if (result.clearInput) _urlController.clear();
    _showAddResult(result);
    setState(() => _isAdding = false);
  }

  Future<void> _refreshAll() async {
    setState(() {
      _isRefreshing = true;
      _refreshResult = null;
    });

    final controller = _subscriptionController(
      context.read<SubscriptionService>(),
    );
    final result = await controller.refreshAll();
    if (!mounted) return;

    setState(() {
      _refreshResult = result.message;
      _isRefreshing = false;
    });
    if (result.shouldShowNetworkHelp) {
      _showNetworkErrorDialog(result.networkErrorDetail!);
    }
  }

  SubscriptionScreenController _subscriptionController(
    SubscriptionService subService,
  ) {
    return SubscriptionScreenController(
      subscriptionService: CallbackSubscriptionScreenService(
        subscriptionsOf: () => subService.subscriptions,
        allNodesOf: () => subService.allNodes,
        allGroupsOf: () => subService.allGroups,
        isSingleNodeLinkOf: subService.isSingleNodeLink,
        defaultSubscriptionNameOf: subService.defaultSubscriptionName,
        addSubscriptionWith: subService.addSubscription,
        refreshAllSubscriptionsWith: subService.refreshAllSubscriptions,
        removeSubscriptionWith: subService.removeSubscription,
      ),
    );
  }

  void _showAddResult(SubscriptionAddResult result) {
    switch (result.status) {
      case SubscriptionAddStatus.emptyInput:
        _showSnack(
          '请输入订阅链接或SSR链接',
          AppTheme.error,
          behavior: SnackBarBehavior.floating,
        );
      case SubscriptionAddStatus.duplicate:
        _showSnack('该订阅已存在，无需重复添加', AppTheme.warning);
      case SubscriptionAddStatus.invalidUrl:
        _showSnack('请输入有效的URL地址', AppTheme.error);
      case SubscriptionAddStatus.singleNodeImported:
        _showSnack('SSR链接已导入，当前共 ${result.nodeCount} 个节点', AppTheme.success);
      case SubscriptionAddStatus.singleNodeNoData:
        _showSnack('SSR链接已添加，但未获取到数据', AppTheme.warning);
      case SubscriptionAddStatus.singleNodeImportFailed:
        _showSnack('导入失败: ${result.error}', AppTheme.error);
      case SubscriptionAddStatus.subscriptionAdded:
        _showSnack('订阅成功，获取到 ${result.nodeCount} 个节点', AppTheme.success);
      case SubscriptionAddStatus.subscriptionNoData:
        _showSnack('订阅已添加，但未获取到数据', AppTheme.warning);
      case SubscriptionAddStatus.refreshFailed:
        final msg = result.error.toString().replaceFirst('Exception: ', '');
        _showSnack(
          '刷新失败: $msg',
          AppTheme.error,
          duration: const Duration(seconds: 4),
        );
      case SubscriptionAddStatus.failed:
        _showSnack('添加失败: ${result.error}', AppTheme.error);
    }
  }

  void _showSnack(
    String message,
    Color backgroundColor, {
    Duration? duration,
    SnackBarBehavior? behavior,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: behavior,
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  void _showNetworkErrorDialog(String detail) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Dialog(
          backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.88),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withValues(alpha: 20 / 255),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.wifi_off_rounded,
                        size: 28, color: AppTheme.warning),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '网络连接异常',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请检查网络连接后重试',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 10 / 255),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      detail,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.error.withValues(alpha: 180 / 255)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        backgroundColor: AppTheme.primary
                            .withValues(alpha: (isDark ? 25 : 15) / 255),
                      ),
                      child: const Text('知道了',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _deleteSubscription(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.88),
          child: GlassContainer(
            borderRadius: 20,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 48,
                  color: AppTheme.warning,
                ),
                const SizedBox(height: 16),
                const Text(
                  '确认删除',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '删除后将无法恢复',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 120 / 255)
                        : AppTheme.lightTextSecondary,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.error,
                        ),
                        child: const Text('删除'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed == true) {
      if (!mounted) return;
      final subService = context.read<SubscriptionService>();
      final clashService = context.read<ClashService>();
      final result = await _subscriptionController(subService)
          .deleteSubscription(
        id,
        clashRunning: clashService.isRunning,
        stopClash: clashService.stop,
        continueAfterRefreshFailure: true,
      )
          .catchError((Object e) {
        return SubscriptionDeleteResult(removed: false, error: e);
      });
      if (!mounted) return;

      if (!result.removed) {
        _showSnack(
          '删除失败：${result.error.toString().replaceFirst("Exception: ", "")}',
          AppTheme.error,
        );
      } else if (result.remainingRefreshFailed) {
        _showSnack('订阅已删除，但刷新剩余订阅失败，请稍后重试', AppTheme.warning);
      } else if (result.error != null) {
        _showSnack(
          '订阅已删除，但断开 VPN 失败：${result.error.toString().replaceFirst("Exception: ", "")}',
          AppTheme.warning,
        );
      }
      if (result.stoppedClash) {
        _showSnack('订阅已删除，VPN 已断开', AppTheme.warning);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final subService = context.watch<SubscriptionService>();
    final subscriptions = subService.subscriptions;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth < 420 ? 16.0 : 24.0;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: 16,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DesktopSubscriptionHeader(
                        isDark: isDark,
                        onAboutTap: () =>
                            _showDesktopSubscriptionAboutDialog(context),
                      ),
                      const SizedBox(height: 24),
                      _DesktopSubscriptionAddCard(
                        isDark: isDark,
                        urlController: _urlController,
                        isAdding: _isAdding,
                        onAdd: _addSubscription,
                      ),
                      const SizedBox(height: 28),
                      if (subscriptions.isNotEmpty)
                        _DesktopSubscriptionListSection(
                          subscriptions: subscriptions,
                          isDark: isDark,
                          isRefreshing: _isRefreshing,
                          refreshResult: _refreshResult,
                          onRefresh: _refreshAll,
                          onDelete: _deleteSubscription,
                        ),
                      if (subscriptions.isEmpty)
                        _DesktopSubscriptionEmptyState(isDark: isDark),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

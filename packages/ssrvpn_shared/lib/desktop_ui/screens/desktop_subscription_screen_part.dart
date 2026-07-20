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
  bool _isDeleting = false;
  SubscriptionRefreshResult? _refreshResult;
  SubscriptionRefreshCancellation? _refreshCancellation;

  bool get _hasBlockingOperation => _isAdding || _isRefreshing || _isDeleting;

  @override
  void dispose() {
    _refreshCancellation?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addSubscription() async {
    if (_hasBlockingOperation) return;
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
    if (_hasBlockingOperation) return;
    final cancellation = SubscriptionRefreshCancellation();
    _refreshCancellation = cancellation;
    setState(() {
      _isRefreshing = true;
      _refreshResult = null;
    });

    final controller = _subscriptionController(
      context.read<SubscriptionService>(),
    );
    final result = await controller.refreshAll(cancellation: cancellation);
    if (!mounted || !identical(_refreshCancellation, cancellation)) return;

    setState(() {
      _refreshCancellation = null;
      _refreshResult = result;
      _isRefreshing = false;
    });
    if (result.shouldShowNetworkHelp) {
      _showNetworkErrorDialog(result.networkErrorDetail!);
    }
  }

  void _cancelRefresh() {
    _refreshCancellation?.cancel();
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
        refreshAllSubscriptionsDetailedWith:
            subService.refreshAllSubscriptionsDetailed,
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
        _showSnack('导入失败: ${result.displayError}', AppTheme.error);
      case SubscriptionAddStatus.subscriptionAdded:
        _showSnack('订阅成功，获取到 ${result.nodeCount} 个节点', AppTheme.success);
      case SubscriptionAddStatus.subscriptionNoData:
        _showSnack('订阅已添加，但未获取到数据', AppTheme.warning);
      case SubscriptionAddStatus.refreshFailed:
        _showSnack(
          '刷新失败: ${result.displayError}',
          AppTheme.error,
          duration: const Duration(seconds: 4),
        );
      case SubscriptionAddStatus.failed:
        _showSnack('添加失败: ${result.displayError}', AppTheme.error);
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
      builder: (_) => SsrvpnSubscriptionErrorDialog(detail: detail),
    );
  }

  Future<void> _deleteSubscription(String id) async {
    if (_hasBlockingOperation) return;
    setState(() => _isDeleting = true);
    try {
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
        final result =
            await _subscriptionController(subService).deleteSubscription(
          id,
          clashRunning:
              clashService.isRunning || clashService.connectionDesired,
          stopClash: () async {
            clashService.requestConnectionIntent(false);
            clashService.interruptPendingStart();
            await clashService.runConnectionTransition(clashService.stop);
          },
        ).catchError((Object e) {
          return SubscriptionDeleteResult(removed: false, error: e);
        });
        if (!mounted) return;

        if (!result.removed) {
          _showSnack(
            '删除失败：${result.displayError}',
            AppTheme.error,
          );
        } else if (result.error != null) {
          _showSnack(
            '订阅已删除，但断开 VPN 失败：${result.displayError}',
            AppTheme.warning,
          );
        } else if (result.stoppedClash) {
          _showSnack('订阅已删除，VPN 已断开', AppTheme.warning);
        } else {
          _showSnack('订阅已删除', AppTheme.success);
        }
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subService = context.watch<SubscriptionService>();
    final refreshResult = _refreshResult;
    final refreshColor = switch (refreshResult?.status) {
      SubscriptionRefreshStatus.success => SsrvpnUiTokens.success,
      SubscriptionRefreshStatus.partialSuccess => SsrvpnUiTokens.warning,
      SubscriptionRefreshStatus.failure => SsrvpnUiTokens.error,
      SubscriptionRefreshStatus.cancelled => SsrvpnUiTokens.textSecondary,
      null => null,
    };

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SsrvpnSubscriptionView(
        subscriptions: subService.subscriptions,
        urlController: _urlController,
        isAdding: _isAdding,
        isRefreshing: _isRefreshing,
        isBusy: _hasBlockingOperation,
        refreshMessage: refreshResult?.message,
        refreshMessageColor: refreshColor,
        onAdd: _addSubscription,
        onRefresh: _refreshAll,
        onCancelRefresh: _cancelRefresh,
        onDelete: _deleteSubscription,
      ),
    );
  }
}

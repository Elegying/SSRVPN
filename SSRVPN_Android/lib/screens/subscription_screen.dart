import '../utils/responsive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_container.dart';
import '../widgets/subscription_network_error_dialog.dart';

/// 订阅管理页面 - 液态玻璃风格
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final _urlController = TextEditingController();
  bool _isAdding = false;
  bool _isRefreshing = false;
  bool _isDeleting = false;
  SubscriptionRefreshResult? _refreshResult;
  SubscriptionRefreshCancellation? _refreshCancellation;

  bool get _isBusy => _isAdding || _isRefreshing || _isDeleting;

  @override
  void dispose() {
    _refreshCancellation?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addSubscription() async {
    if (_isBusy) return;
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
    if (_isBusy) return;
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
      _refreshResult = result;
      _isRefreshing = false;
      _refreshCancellation = null;
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
        _showSnack('请输入订阅链接或SSR链接', AppTheme.errorColor);
      case SubscriptionAddStatus.duplicate:
        _showSnack('该订阅已存在，无需重复添加', AppTheme.warningColor);
      case SubscriptionAddStatus.invalidUrl:
        _showSnack('请输入有效的URL地址', AppTheme.errorColor);
      case SubscriptionAddStatus.singleNodeImported:
        _showSnack(
          'SSR链接已导入，当前共 ${result.nodeCount} 个节点',
          AppTheme.successColor,
        );
      case SubscriptionAddStatus.singleNodeNoData:
        _showSnack('SSR链接已添加，但未获取到数据', AppTheme.warningColor);
      case SubscriptionAddStatus.singleNodeImportFailed:
        _showSnack('导入失败，请检查链接是否有效', AppTheme.errorColor);
      case SubscriptionAddStatus.subscriptionAdded:
        _showSnack('订阅成功，获取到 ${result.nodeCount} 个节点', AppTheme.successColor);
      case SubscriptionAddStatus.subscriptionNoData:
        _showSnack('订阅已添加，但未获取到数据', AppTheme.warningColor);
      case SubscriptionAddStatus.refreshFailed:
        _showSnack(
          '刷新失败，请检查网络后重试',
          AppTheme.errorColor,
          duration: const Duration(seconds: 4),
        );
      case SubscriptionAddStatus.failed:
        _showSnack('添加失败，请检查链接是否有效', AppTheme.errorColor);
    }
  }

  void _showSnack(String message, Color backgroundColor, {Duration? duration}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
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
      builder: (_) => SubscriptionNetworkErrorDialog(detail: detail),
    );
  }

  Future<void> _deleteSubscription(String id) async {
    if (!mounted || _isBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: GlassContainer(
          borderRadius: 20,
          padding: EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(ctx).size.width * 0.82,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 48,
                  color: AppTheme.warningColor,
                ),
                SizedBox(height: 16),
                Text(
                  '确认删除',
                  style: TextStyle(
                      fontSize: Responsive.sp(18), fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                Text(
                  '删除后将无法恢复，确定要删除吗？',
                  style: TextStyle(
                    fontSize: Responsive.sp(13),
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 120 / 255)
                        : AppTheme.lightTextSecondary,
                  ),
                ),
                SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text('取消'),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.errorColor,
                        ),
                        child: Text('删除'),
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
      if (!mounted || _isBusy) return;
      setState(() => _isDeleting = true);
      final subService = context.read<SubscriptionService>();
      final clashService = context.read<ClashService>();
      late final SubscriptionDeleteResult result;
      try {
        result = await _subscriptionController(subService).deleteSubscription(
          id,
          clashRunning: clashService.isRunning,
          stopClash: () async {
            clashService.requestConnectionIntent(false);
            await clashService.stop();
          },
          onNoRunnableNodes: () async {
            await clashService.clearNativeConnectionSnapshot();
          },
        );
      } catch (e) {
        if (mounted) {
          final displayError = SubscriptionDeleteResult(
            removed: false,
            error: e,
          ).displayError;
          _showSnack(
            '删除失败：$displayError',
            AppTheme.errorColor,
          );
        }
        return;
      } finally {
        if (mounted) setState(() => _isDeleting = false);
      }

      if (!mounted) return;

      if (!result.removed) {
        _showSnack(
          '删除失败：${result.displayError}',
          AppTheme.errorColor,
        );
      } else if (result.error != null) {
        _showSnack(
          '订阅已删除，但断开 VPN 失败：${result.displayError}',
          AppTheme.warningColor,
        );
      } else if (result.stoppedClash) {
        _showSnack('订阅已删除，VPN 已断开', AppTheme.warningColor);
      } else {
        _showSnack('订阅已删除', AppTheme.successColor);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
        isBusy: _isBusy,
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

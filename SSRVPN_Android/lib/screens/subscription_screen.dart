import '../utils/responsive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_container.dart';
import '../widgets/liquid_glass.dart' hide GlassInputDecoration;
import '../widgets/subscription_screen_sections.dart';

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
      _showWifiDialog(result.networkErrorDetail!);
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

  /// 网络异常时弹窗提示连接 WiFi
  void _showWifiDialog(String detail) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: GlassContainer(
            borderRadius: 16,
            enablePress: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(ctx).size.width * 0.88,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color:
                            AppTheme.warningColor.withValues(alpha: 20 / 255),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.wifi_off_rounded,
                          size: 28, color: AppTheme.warningColor),
                    ),
                    SizedBox(height: 16),
                    Text(
                      '请连接 WiFi 后再刷新',
                      style: TextStyle(
                        fontSize: Responsive.sp(16),
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.lightTextPrimary,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '当前移动数据网络异常，建议连接 WiFi 后重试',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: Responsive.sp(13),
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                    SizedBox(height: 6),
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.errorColor.withValues(alpha: 10 / 255),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        detail,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: Responsive.sp(11),
                            color: AppTheme.errorColor
                                .withValues(alpha: 180 / 255)),
                      ),
                    ),
                    SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          backgroundColor: AppTheme.primaryColor
                              .withValues(alpha: (isDark ? 25 : 15) / 255),
                        ),
                        child: Text('知道了',
                            style: TextStyle(
                                fontSize: Responsive.sp(14),
                                fontWeight: FontWeight.w600,
                                color: AppTheme.primaryColor)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _deleteSubscription(String id) async {
    if (!mounted) return;
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
      if (!mounted) return;
      setState(() => _isDeleting = true);
      final subService = context.read<SubscriptionService>();
      final clashService = context.read<ClashService>();
      late final SubscriptionDeleteResult result;
      try {
        result = await _subscriptionController(subService).deleteSubscription(
          id,
          clashRunning: clashService.isRunning,
          stopClash: clashService.stop,
        );
      } catch (e) {
        if (mounted) {
          _showSnack(
            '删除失败：${e.toString().replaceFirst("Exception: ", "")}',
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
          '删除失败：${result.error.toString().replaceFirst("Exception: ", "")}',
          AppTheme.errorColor,
        );
      } else if (result.error != null) {
        _showSnack(
          '订阅已删除，但断开 VPN 失败：${result.error.toString().replaceFirst("Exception: ", "")}',
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
    final subscriptions = subService.subscriptions;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.of(context).padding.bottom +
                  LiquidGlassNavBar.height +
                  20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SubscriptionHeader(
                isDark: isDark,
                onAboutTap: () => _showAboutDialog(context),
              ),
              const SizedBox(height: 20),
              SubscriptionAddCard(
                isDark: isDark,
                urlController: _urlController,
                isAdding: _isAdding,
                onAdd: _addSubscription,
              ),
              const SizedBox(height: 24),
              if (subscriptions.isNotEmpty)
                SubscriptionListSection(
                  subscriptions: subscriptions,
                  isDark: isDark,
                  isRefreshing: _isRefreshing,
                  isDeleting: _isDeleting,
                  refreshResult: _refreshResult,
                  onRefresh: _refreshAll,
                  onDelete: _deleteSubscription,
                ),
              if (subscriptions.isEmpty) SubscriptionEmptyState(isDark: isDark),
            ],
          ),
        ),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
              maxWidth: MediaQuery.of(ctx).size.width * 0.88,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppTheme.primaryColor, AppTheme.accentColor],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.vpn_lock_rounded,
                        size: 28, color: Colors.white),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'SSRVPN',
                    style: TextStyle(
                      fontSize: Responsive.sp(20),
                      fontWeight: FontWeight.w800,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'v${UpdateService.appVersion}',
                    style: TextStyle(
                      fontSize: Responsive.sp(13),
                      color: AppTheme.primaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 5 / 255)
                          : Colors.black.withValues(alpha: 5 / 255),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '项目地址',
                          style: TextStyle(
                            fontSize: Responsive.sp(12),
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.lightTextPrimary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'https://github.com/Elegying/SSRVPN',
                          style: TextStyle(
                            fontSize: Responsive.sp(12),
                            height: 1.4,
                            color: AppTheme.accentColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 5 / 255)
                          : Colors.black.withValues(alpha: 5 / 255),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '免责声明',
                          style: TextStyle(
                            fontSize: Responsive.sp(12),
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.lightTextPrimary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '本软件仅供学习与研究使用，请遵守当地法律法规。\n使用者应对自身行为承担全部责任，开发者不对因使用本软件产生的任何后果负责。',
                          style: TextStyle(
                            fontSize: Responsive.sp(12),
                            height: 1.5,
                            color: isDark
                                ? AppTheme.darkTextSecondary
                                : AppTheme.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'By--两颗西柚',
                    style: TextStyle(
                      fontSize: Responsive.sp(13),
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                  SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        backgroundColor: AppTheme.primaryColor
                            .withValues(alpha: (isDark ? 25 : 15) / 255),
                      ),
                      child: Text('知道了',
                          style: TextStyle(
                              fontSize: Responsive.sp(14),
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryColor)),
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
}

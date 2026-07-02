import '../utils/responsive.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_container.dart';
import '../widgets/liquid_glass.dart' hide GlassInputDecoration;

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
    final url = _urlController.text.trim();

    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text('请输入订阅链接或SSR链接'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }

    setState(() => _isAdding = true);

    try {
      final subService = context.read<SubscriptionService>();

      if (subService.subscriptions.any((s) => s.url == url)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
            content: Text('该订阅已存在，无需重复添加'),
            backgroundColor: AppTheme.warningColor,
          ),
        );
        return;
      }

      if (subService.isSsrLink(url)) {
        // SSR链接作为订阅条目保存，刷新时自动解析
        await subService.addSubscription('SSR节点', url);
        _urlController.clear();

        try {
          final yaml = await subService.refreshAllSubscriptions();
          if (mounted) {
            if (yaml != null && yaml.isNotEmpty) {
              final nodeCount = subService.allNodes.length;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  margin:  EdgeInsets.fromLTRB(16, 0, 16, 88),
                  content: Text('SSR链接已导入，当前共 $nodeCount 个节点'),
                  backgroundColor: AppTheme.successColor,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
                  content: Text('SSR链接已添加，但未获取到数据'),
                  backgroundColor: AppTheme.warningColor,
                ),
              );
            }
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                margin:  EdgeInsets.fromLTRB(16, 0, 16, 88),
                content: Text('导入失败，请检查链接是否有效'),
                backgroundColor: AppTheme.errorColor,
              ),
            );
          }
        }
      } else {
        final parsedUri = Uri.tryParse(url);
        if (parsedUri == null || !parsedUri.hasScheme) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
                content: Text('请输入有效的URL地址'),
                backgroundColor: AppTheme.errorColor,
              ),
            );
          }
          return;
        }

        await subService.addSubscription('SSRVPN.VIP', url);
        _urlController.clear();

        // 自动刷新订阅
        try {
          final yaml = await subService.refreshAllSubscriptions();
          if (mounted) {
            if (yaml != null && yaml.isNotEmpty) {
              final nodeCount = subService.allNodes.length;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  margin:  EdgeInsets.fromLTRB(16, 0, 16, 88),
                  content: Text('订阅成功，获取到 $nodeCount 个节点'),
                  backgroundColor: AppTheme.successColor,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
                  content: Text('订阅已添加，但未获取到数据'),
                  backgroundColor: AppTheme.warningColor,
                ),
              );
            }
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                margin:  EdgeInsets.fromLTRB(16, 0, 16, 88),
                content: Text('刷新失败，请检查网络后重试'),
                backgroundColor: AppTheme.errorColor,
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            margin:  EdgeInsets.fromLTRB(16, 0, 16, 88),
            content: Text('添加失败，请检查链接是否有效'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<void> _refreshAll() async {
    setState(() {
      _isRefreshing = true;
      _refreshResult = null;
    });

    try {
      final subService = context.read<SubscriptionService>();
      final yaml = await subService.refreshAllSubscriptions();
      if (!mounted) return;

      if (yaml != null && yaml.isNotEmpty) {
        final nodeCount = subService.allNodes.length;
        final groupCount = subService.allGroups.length;
        setState(() {
          _refreshResult = '成功: 获取到 $nodeCount 个节点, $groupCount 个分组';
        });
      } else {
        setState(() => _refreshResult = '刷新失败: 没有可用的订阅');
      }
    } on SocketException catch (e) {
      if (!mounted) return;
      setState(() => _refreshResult = '刷新失败: 网络连接异常');
      _showWifiDialog(e.message);
    } on TimeoutException catch (_) {
      if (!mounted) return;
      setState(() => _refreshResult = '刷新失败: 连接超时');
      _showWifiDialog('连接超时，请检查网络');
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      setState(() => _refreshResult = '刷新失败: $msg');
      // 网络相关错误弹窗提示连接 WiFi
      if (msg.contains('网络') ||
          msg.contains('连接') ||
          msg.contains('Socket') ||
          msg.contains('超时') ||
          msg.contains('DNS')) {
        _showWifiDialog(msg);
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
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
                padding:  EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppTheme.warningColor.withValues(alpha: 20 / 255),
                        shape: BoxShape.circle,
                      ),
                      child:  Icon(Icons.wifi_off_rounded,
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
                      padding:  EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.errorColor.withValues(alpha: 10 / 255),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        detail,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: Responsive.sp(11),
                            color: AppTheme.errorColor.withValues(alpha: 180 / 255)),
                      ),
                    ),
                     SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: TextButton.styleFrom(
                          padding:  EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          backgroundColor:
                              AppTheme.primaryColor.withValues(alpha: (isDark ? 25 : 15) / 255),
                        ),
                        child:  Text('知道了',
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
    setState(() => _isDeleting = true);
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
                  style: TextStyle(fontSize: Responsive.sp(18), fontWeight: FontWeight.w600),
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
      try {
        await subService.removeSubscription(id);
        // 节点已清空时不能让 VPN 继续用已删除的配置跑流量
        if (subService.allNodes.isEmpty && clashService.isRunning) {
          await clashService.stop();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
                content: Text('订阅已删除，VPN 已断开'),
                backgroundColor: AppTheme.warningColor,
                duration: Duration(seconds: 4),
              ),
            );
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
              content: Text('订阅已删除'),
              backgroundColor: AppTheme.successColor,
              duration: Duration(seconds: 4),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
              content: Text('删除失败：${e.toString().replaceFirst("Exception: ", "")}'),
              backgroundColor: AppTheme.errorColor,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _isDeleting = false);
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
              // 标题区
              _buildHeader(isDark),
               SizedBox(height: 20),

              // 添加订阅卡片
              _buildAddCard(isDark),
               SizedBox(height: 24),

              // 订阅列表
              if (subscriptions.isNotEmpty)
                _buildSubscriptionList(subService, subscriptions, isDark),

              // 空状态
              if (subscriptions.isEmpty) _buildEmptyState(isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient:  LinearGradient(
              colors: [AppTheme.primaryColor, AppTheme.accentColor],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child:  Icon(Icons.rss_feed, color: Colors.white, size: 20),
        ),
         SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '订阅管理',
              style: TextStyle(
                fontSize: Responsive.sp(22),
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : AppTheme.lightTextPrimary,
              ),
            ),
             SizedBox(height: 2),
            Text(
              '支持订阅链接与 ssr:// 导入',
              style: TextStyle(
                fontSize: Responsive.sp(12),
                color: isDark
                    ? Colors.white.withValues(alpha: 100 / 255)
                    : AppTheme.lightTextSecondary,
              ),
            ),
          ],
        ),
        const Spacer(),
        GestureDetector(
          onTap: () => _showAboutDialog(context),
          child: Container(
            height: 34,
            padding:  EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 20 / 255),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 55 / 255)),
            ),
            child:  Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 16, color: AppTheme.primaryColor),
                SizedBox(width: 6),
                Text(
                  '关于',
                  style: TextStyle(
                    fontSize: Responsive.sp(12),
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
              padding:  EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration:  BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppTheme.primaryColor, AppTheme.accentColor],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child:  Icon(Icons.vpn_lock_rounded,
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
                    padding:  EdgeInsets.all(12),
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
                          'https://github.com/Elegying/SSRVPN_Android',
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
                    padding:  EdgeInsets.all(12),
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
                        padding:  EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        backgroundColor:
                            AppTheme.primaryColor.withValues(alpha: (isDark ? 25 : 15) / 255),
                      ),
                      child:  Text('知道了',
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

  Widget _buildAddCard(bool isDark) {
    return GlassContainer(
      borderRadius: 18,
      padding:  EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
               Icon(
                Icons.add_circle_outline,
                size: 18,
                color: AppTheme.accentColor,
              ),
               SizedBox(width: 8),
              Text(
                '添加订阅',
                style: TextStyle(
                  fontSize: Responsive.sp(15),
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : AppTheme.lightTextPrimary,
                ),
              ),
            ],
          ),
           SizedBox(height: 16),

          // 链接输入框
          TextField(
            controller: _urlController,
            decoration: GlassInputDecoration(
              isDark: isDark,
              hintText: '粘贴订阅链接或 ssr:// 链接',
              prefixIcon:  Icon(Icons.link, size: 20),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _addSubscription(),
          ),
           SizedBox(height: 14),

          // 添加按钮
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _isAdding ? null : _addSubscription,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                disabledBackgroundColor: AppTheme.primaryColor.withValues(alpha: 100 / 255),
                foregroundColor: Colors.white,
                shadowColor: AppTheme.primaryColor.withValues(alpha: 60 / 255),
                elevation: 4,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding:  EdgeInsets.symmetric(vertical: 14),
                textStyle:
                    TextStyle(fontSize: Responsive.sp(16), fontWeight: FontWeight.w600),
              ),
              child: _isAdding
                  ?  SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  :  Text('添加'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionList(
    SubscriptionService subService,
    List<Subscription> subscriptions,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 列表头部
        Row(
          children: [
            Text(
              '我的订阅',
              style: TextStyle(
                fontSize: Responsive.sp(16),
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : AppTheme.lightTextPrimary,
              ),
            ),
             SizedBox(width: 8),
            Container(
              padding:  EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 30 / 255),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${subscriptions.length}',
                style: TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: Responsive.sp(12),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _isRefreshing ? null : _refreshAll,
              icon: _isRefreshing
                  ?  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primaryColor,
                      ),
                    )
                  :  Icon(Icons.refresh, size: 18),
              label: Text(_isRefreshing ? '刷新中...' : '全部刷新'),
            ),
          ],
        ),
         SizedBox(height: 8),

        // 刷新结果
        if (_refreshResult != null) _buildRefreshResult(isDark),

        // 订阅卡片
        ...subscriptions.map((sub) => _buildSubscriptionCard(sub, isDark)),
      ],
    );
  }

  Widget _buildRefreshResult(bool isDark) {
    final isSuccess = _refreshResult!.startsWith('成功');
    return Container(
      margin:  EdgeInsets.only(bottom: 12),
      padding:  EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSuccess
            ? AppTheme.successColor.withValues(alpha: (isDark ? 15 : 20) / 255)
            : AppTheme.errorColor.withValues(alpha: (isDark ? 15 : 20) / 255),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSuccess
              ? AppTheme.successColor.withValues(alpha: 40 / 255)
              : AppTheme.errorColor.withValues(alpha: 40 / 255),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSuccess ? Icons.check_circle : Icons.error_outline,
            color: isSuccess ? AppTheme.successColor : AppTheme.errorColor,
            size: 18,
          ),
           SizedBox(width: 8),
          Expanded(
            child: Text(
              _refreshResult!,
              style: TextStyle(
                fontSize: Responsive.sp(12),
                color: isSuccess ? AppTheme.successColor : AppTheme.errorColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionCard(Subscription sub, bool isDark) {
    return GlassContainer(
      borderRadius: 14,
      margin:  EdgeInsets.only(bottom: 10),
      padding:  EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 图标
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.primaryColor.withValues(alpha: 40 / 255),
                      AppTheme.accentColor.withValues(alpha: 40 / 255),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child:  Icon(
                  Icons.rss_feed,
                  color: AppTheme.primaryColor,
                  size: 20,
                ),
              ),
               SizedBox(width: 12),

              // 名称和链接
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sub.name,
                      style: TextStyle(
                        fontSize: Responsive.sp(15),
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white : AppTheme.lightTextPrimary,
                      ),
                    ),
                     SizedBox(height: 3),
                    Text(
                      sub.url,
                      style: TextStyle(
                        fontSize: Responsive.sp(11),
                        color: isDark
                            ? Colors.white.withValues(alpha: 60 / 255)
                            : AppTheme.lightTextHint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // 删除按钮
              _isDeleting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.errorColor.withValues(alpha: 150 / 255),
                      ),
                    )
                  : IconButton(
                onPressed: () => _deleteSubscription(sub.id),
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: AppTheme.errorColor.withValues(alpha: 150 / 255),
                ),
                padding:  EdgeInsets.all(4),
                constraints:  BoxConstraints(),
                tooltip: '删除订阅',
              ),
            ],
          ),
           SizedBox(height: 12),

          // 状态栏
          Row(
            children: [
              _buildStatusDot(
                sub.enabled ? AppTheme.successColor : AppTheme.errorColor,
              ),
               SizedBox(width: 5),
              Text(
                sub.enabled ? '已启用' : '已禁用',
                style: TextStyle(
                  fontSize: Responsive.sp(11),
                  color:
                      sub.enabled ? AppTheme.successColor : AppTheme.errorColor,
                ),
              ),
               SizedBox(width: 16),
              Icon(
                Icons.access_time,
                size: 13,
                color: isDark
                    ? Colors.white.withValues(alpha: 60 / 255)
                    : AppTheme.lightTextHint,
              ),
               SizedBox(width: 4),
              Text(
                sub.lastUpdate != null
                    ? '更新于 ${_formatDate(sub.lastUpdate!)}'
                    : '未更新',
                style: TextStyle(
                  fontSize: Responsive.sp(11),
                  color: isDark
                      ? Colors.white.withValues(alpha: 60 / 255)
                      : AppTheme.lightTextHint,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusDot(Color color) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 100 / 255), blurRadius: 4),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding:  EdgeInsets.only(top: 60),
        child: Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.primaryColor.withValues(alpha: 20 / 255),
                    AppTheme.accentColor.withValues(alpha: 20 / 255),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.rss_feed,
                size: 36,
                color: AppTheme.primaryColor.withValues(alpha: 100 / 255),
              ),
            ),
             SizedBox(height: 20),
            Text(
              '暂无订阅',
              style: TextStyle(
                fontSize: Responsive.sp(16),
                fontWeight: FontWeight.w500,
                color: isDark
                    ? Colors.white.withValues(alpha: 120 / 255)
                    : AppTheme.lightTextSecondary,
              ),
            ),
             SizedBox(height: 8),
            Text(
              '在上方粘贴订阅链接开始使用',
              style: TextStyle(
                fontSize: Responsive.sp(12),
                color: isDark
                    ? Colors.white.withValues(alpha: 60 / 255)
                    : AppTheme.lightTextHint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${date.month}/${date.day} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

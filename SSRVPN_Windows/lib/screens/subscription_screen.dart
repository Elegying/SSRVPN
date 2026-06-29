import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_container.dart';

/// 订阅管理页面 - Windows 桌面优化
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
    final url = _urlController.text.trim();

    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('请输入订阅链接或SSR链接'),
          backgroundColor: AppTheme.error,
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
            content: Text('该订阅已存在，无需重复添加'),
            backgroundColor: AppTheme.warning,
          ),
        );
        return;
      }

      if (subService.isSsrLink(url)) {
        await subService.addSubscription('SSR节点', url);
        _urlController.clear();

        try {
          final yaml = await subService.refreshAllSubscriptions();
          if (mounted) {
            if (yaml != null && yaml.isNotEmpty) {
              final nodeCount = subService.allNodes.length;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('SSR链接已导入，当前共 $nodeCount 个节点'),
                  backgroundColor: AppTheme.success,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('SSR链接已添加，但未获取到数据'),
                  backgroundColor: AppTheme.warning,
                ),
              );
            }
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('导入失败: $e'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
        }
      } else {
        final parsedUri = Uri.tryParse(url);
        if (parsedUri == null ||
            !parsedUri.hasAuthority ||
            (parsedUri.scheme != 'http' && parsedUri.scheme != 'https')) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('请输入有效的URL地址'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
          return;
        }

        await subService.addSubscription('SSRVPN.VIP', url);
        _urlController.clear();

        try {
          final yaml = await subService.refreshAllSubscriptions();
          if (mounted) {
            if (yaml != null && yaml.isNotEmpty) {
              final nodeCount = subService.allNodes.length;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('订阅成功，获取到 $nodeCount 个节点'),
                  backgroundColor: AppTheme.success,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('订阅已添加，但未获取到数据'),
                  backgroundColor: AppTheme.warning,
                ),
              );
            }
          }
        } catch (e) {
          if (mounted) {
            final msg = e.toString().replaceFirst('Exception: ', '');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('刷新失败: $msg'),
                backgroundColor: AppTheme.error,
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
            content: Text('添加失败: $e'),
            backgroundColor: AppTheme.error,
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
      _showNetworkErrorDialog(e.message);
    } on TimeoutException catch (_) {
      if (!mounted) return;
      setState(() => _refreshResult = '刷新失败: 连接超时');
      _showNetworkErrorDialog('连接超时，请检查网络');
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      setState(() => _refreshResult = '刷新失败: $msg');
      if (msg.contains('网络') ||
          msg.contains('连接') ||
          msg.contains('Socket') ||
          msg.contains('超时') ||
          msg.contains('DNS')) {
        _showNetworkErrorDialog(msg);
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
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
                        backgroundColor:
                            AppTheme.primary.withValues(alpha: (isDark ? 25 : 15) / 255),
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
      try {
        await subService.removeSubscription(id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('订阅已删除，但刷新剩余订阅失败，请稍后重试'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
      if (subService.allNodes.isEmpty && clashService.isRunning) {
        await clashService.stop();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('订阅已删除，VPN 已断开'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
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
                      _buildHeader(isDark),
                      const SizedBox(height: 24),
                      _buildAddCard(isDark),
                      const SizedBox(height: 28),
                      if (subscriptions.isNotEmpty)
                        _buildSubscriptionList(
                          subService,
                          subscriptions,
                          isDark,
                        ),
                      if (subscriptions.isEmpty) _buildEmptyState(isDark),
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

  Widget _buildHeader(bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;
        final titleBlock = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '订阅管理',
                style: TextStyle(
                  fontSize: compact ? 22 : 24,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : AppTheme.lightTextPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '支持订阅链接与 ssr:// 导入',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 12 : 13,
                  color: isDark
                      ? Colors.white.withValues(alpha: 100 / 255)
                      : AppTheme.lightTextSecondary,
                ),
              ),
            ],
          ),
        );

        return Row(
          children: [
            Container(
              width: compact ? 40 : 44,
              height: compact ? 40 : 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primary, AppTheme.accentColor],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.rss_feed,
                color: Colors.white,
                size: compact ? 20 : 22,
              ),
            ),
            SizedBox(width: compact ? 12 : 16),
            titleBlock,
            const SizedBox(width: 12),
            _AboutButton(onTap: () => _showAboutDialog(context)),
          ],
        );
      },
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
              maxWidth: (MediaQuery.of(ctx).size.width * 0.88)
                  .clamp(
                    280.0,
                    420.0,
                  )
                  .toDouble(),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppTheme.primary, AppTheme.accentColor],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.vpn_lock_rounded,
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'SSRVPN',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'v${UpdateService.appVersion}',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _AboutInfoPanel(
                    title: '项目地址',
                    body: 'https://github.com/Elegying/SSRVPN_Windows',
                    isDark: isDark,
                    accent: true,
                  ),
                  const SizedBox(height: 12),
                  _AboutInfoPanel(
                    title: '免责声明',
                    body:
                        '本软件仅供学习与研究使用，请遵守当地法律法规。\n使用者应对自身行为承担全部责任，开发者不对因使用本软件产生的任何后果负责。',
                    isDark: isDark,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'By--两颗西柚',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
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
                          borderRadius: BorderRadius.circular(10),
                        ),
                        backgroundColor: AppTheme.primary.withValues(alpha: (isDark ? 25 : 15) / 255),
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

  Widget _buildAddCard(bool isDark) {
    return GlassContainer(
      borderRadius: 18,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.add_circle_outline,
                size: 20,
                color: AppTheme.accentColor,
              ),
              const SizedBox(width: 8),
              Text(
                '添加订阅',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : AppTheme.lightTextPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _urlController,
            decoration: GlassInputDecoration(
              isDark: isDark,
              hintText: '粘贴订阅链接或 ssr:// 链接',
              prefixIcon: const Icon(Icons.link, size: 20),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _addSubscription(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _isAdding ? null : _addSubscription,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                disabledBackgroundColor: AppTheme.primary.withValues(alpha: 100 / 255),
                foregroundColor: Colors.white,
                shadowColor: AppTheme.primary.withValues(alpha: 60 / 255),
                elevation: 4,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              child: _isAdding
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('添加'),
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
        Row(
          children: [
            Text(
              '我的订阅',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : AppTheme.lightTextPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 30 / 255),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${subscriptions.length}',
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _isRefreshing ? null : _refreshAll,
              icon: _isRefreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primary,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(_isRefreshing ? '刷新中...' : '全部刷新'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_refreshResult != null) _buildRefreshResult(isDark),
        ...subscriptions.map((sub) => _buildSubscriptionCard(sub, isDark)),
      ],
    );
  }

  Widget _buildRefreshResult(bool isDark) {
    final isSuccess = _refreshResult!.startsWith('成功');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSuccess
            ? AppTheme.success.withValues(alpha: (isDark ? 15 : 20) / 255)
            : AppTheme.error.withValues(alpha: (isDark ? 15 : 20) / 255),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSuccess
              ? AppTheme.success.withValues(alpha: 40 / 255)
              : AppTheme.error.withValues(alpha: 40 / 255),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSuccess ? Icons.check_circle : Icons.error_outline,
            color: isSuccess ? AppTheme.success : AppTheme.error,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _refreshResult!,
              style: TextStyle(
                fontSize: 13,
                color: isSuccess ? AppTheme.success : AppTheme.error,
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
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.primary.withValues(alpha: 40 / 255),
                      AppTheme.accentColor.withValues(alpha: 40 / 255),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.rss_feed,
                  color: AppTheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sub.name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white : AppTheme.lightTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sub.url,
                      style: TextStyle(
                        fontSize: 12,
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
              IconButton(
                onPressed: () => _deleteSubscription(sub.id),
                icon: Icon(
                  Icons.delete_outline,
                  size: 22,
                  color: AppTheme.error.withValues(alpha: 150 / 255),
                ),
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                tooltip: '删除订阅',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildStatusDot(
                sub.enabled ? AppTheme.success : AppTheme.error,
              ),
              const SizedBox(width: 6),
              Text(
                sub.enabled ? '已启用' : '已禁用',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      sub.enabled ? AppTheme.success : AppTheme.error,
                ),
              ),
              const SizedBox(width: 16),
              Icon(
                Icons.access_time,
                size: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 60 / 255)
                    : AppTheme.lightTextHint,
              ),
              const SizedBox(width: 4),
              Text(
                sub.lastUpdate != null
                    ? '更新于 ${_formatDate(sub.lastUpdate!)}'
                    : '未更新',
                style: TextStyle(
                  fontSize: 12,
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
      width: 7,
      height: 7,
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
        padding: const EdgeInsets.only(top: 80),
        child: Column(
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.primary.withValues(alpha: 20 / 255),
                    AppTheme.accentColor.withValues(alpha: 20 / 255),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.rss_feed,
                size: 40,
                color: AppTheme.primary.withValues(alpha: 100 / 255),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '暂无订阅',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? Colors.white.withValues(alpha: 120 / 255)
                    : AppTheme.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '在上方粘贴订阅链接开始使用',
              style: TextStyle(
                fontSize: 13,
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

class _AboutButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AboutButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '关于',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 20 / 255),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 55 / 255)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: AppTheme.primary,
              ),
              SizedBox(width: 6),
              Text(
                '关于',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutInfoPanel extends StatelessWidget {
  final String title;
  final String body;
  final bool isDark;
  final bool accent;

  const _AboutInfoPanel({
    required this.title,
    required this.body,
    required this.isDark,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 5 / 255) : Colors.black.withValues(alpha: 5 / 255),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: accent
                  ? AppTheme.accentColor
                  : (isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

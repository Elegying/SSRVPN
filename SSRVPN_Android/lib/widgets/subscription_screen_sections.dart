import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'glass_container.dart';

class SubscriptionHeader extends StatelessWidget {
  const SubscriptionHeader({
    super.key,
    required this.isDark,
    required this.onAboutTap,
  });

  final bool isDark;
  final VoidCallback onAboutTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.primaryColor, AppTheme.accentColor],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.rss_feed, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 14),
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
            const SizedBox(height: 2),
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
          onTap: onAboutTap,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 20 / 255),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppTheme.primaryColor.withValues(alpha: 55 / 255),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: AppTheme.primaryColor,
                ),
                const SizedBox(width: 6),
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
}

class SubscriptionAddCard extends StatelessWidget {
  const SubscriptionAddCard({
    super.key,
    required this.isDark,
    required this.urlController,
    required this.isAdding,
    required this.onAdd,
  });

  final bool isDark;
  final TextEditingController urlController;
  final bool isAdding;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      borderRadius: 18,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.add_circle_outline,
                size: 18,
                color: AppTheme.accentColor,
              ),
              const SizedBox(width: 8),
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
          const SizedBox(height: 16),
          TextField(
            controller: urlController,
            decoration: GlassInputDecoration(
              isDark: isDark,
              hintText: '粘贴订阅链接或 ssr:// 链接',
              prefixIcon: const Icon(Icons.link, size: 20),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => onAdd(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: isAdding ? null : onAdd,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                disabledBackgroundColor:
                    AppTheme.primaryColor.withValues(alpha: 100 / 255),
                foregroundColor: Colors.white,
                shadowColor: AppTheme.primaryColor.withValues(alpha: 60 / 255),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: TextStyle(
                  fontSize: Responsive.sp(16),
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: isAdding
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('添加'),
            ),
          ),
        ],
      ),
    );
  }
}

class SubscriptionListSection extends StatelessWidget {
  const SubscriptionListSection({
    super.key,
    required this.subscriptions,
    required this.isDark,
    required this.isRefreshing,
    required this.isDeleting,
    required this.refreshResult,
    required this.onRefresh,
    required this.onDelete,
  });

  final List<Subscription> subscriptions;
  final bool isDark;
  final bool isRefreshing;
  final bool isDeleting;
  final String? refreshResult;
  final VoidCallback onRefresh;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              onPressed: isRefreshing ? null : onRefresh,
              icon: isRefreshing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primaryColor,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(isRefreshing ? '刷新中...' : '全部刷新'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (refreshResult != null)
          _SubscriptionRefreshResult(message: refreshResult!, isDark: isDark),
        ...subscriptions.map(
          (sub) => _SubscriptionCard(
            subscription: sub,
            isDark: isDark,
            isDeleting: isDeleting,
            onDelete: () => onDelete(sub.id),
          ),
        ),
      ],
    );
  }
}

class SubscriptionEmptyState extends StatelessWidget {
  const SubscriptionEmptyState({super.key, required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 60),
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
            const SizedBox(height: 20),
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
            const SizedBox(height: 8),
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
}

class _SubscriptionRefreshResult extends StatelessWidget {
  const _SubscriptionRefreshResult({
    required this.message,
    required this.isDark,
  });

  final String message;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final isSuccess = message.startsWith('成功');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
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
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
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
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.subscription,
    required this.isDark,
    required this.isDeleting,
    required this.onDelete,
  });

  final Subscription subscription;
  final bool isDark;
  final bool isDeleting;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      borderRadius: 14,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
                child: const Icon(
                  Icons.rss_feed,
                  color: AppTheme.primaryColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subscription.name,
                      style: TextStyle(
                        fontSize: Responsive.sp(15),
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white : AppTheme.lightTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subscription.url,
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
              isDeleting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.errorColor.withValues(alpha: 150 / 255),
                      ),
                    )
                  : IconButton(
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: AppTheme.errorColor.withValues(alpha: 150 / 255),
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
              _StatusDot(
                color: subscription.enabled
                    ? AppTheme.successColor
                    : AppTheme.errorColor,
              ),
              const SizedBox(width: 5),
              Text(
                subscription.enabled ? '已启用' : '已禁用',
                style: TextStyle(
                  fontSize: Responsive.sp(11),
                  color: subscription.enabled
                      ? AppTheme.successColor
                      : AppTheme.errorColor,
                ),
              ),
              const SizedBox(width: 16),
              Icon(
                Icons.access_time,
                size: 13,
                color: isDark
                    ? Colors.white.withValues(alpha: 60 / 255)
                    : AppTheme.lightTextHint,
              ),
              const SizedBox(width: 4),
              Text(
                subscription.lastUpdate != null
                    ? '更新于 ${_formatDate(subscription.lastUpdate!)}'
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

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
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
}

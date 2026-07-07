part of desktop_subscription_screen;

class _DesktopSubscriptionHeader extends StatelessWidget {
  final bool isDark;
  final VoidCallback onAboutTap;

  const _DesktopSubscriptionHeader({
    required this.isDark,
    required this.onAboutTap,
  });

  @override
  Widget build(BuildContext context) {
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
            _DesktopAboutButton(onTap: onAboutTap),
          ],
        );
      },
    );
  }
}

class _DesktopSubscriptionAddCard extends StatelessWidget {
  final bool isDark;
  final TextEditingController urlController;
  final bool isAdding;
  final VoidCallback onAdd;

  const _DesktopSubscriptionAddCard({
    required this.isDark,
    required this.urlController,
    required this.isAdding,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
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
            controller: urlController,
            decoration: GlassInputDecoration(
              isDark: isDark,
              hintText: '粘贴订阅链接或 ssr:// 链接',
              prefixIcon: const Icon(Icons.link, size: 20),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => onAdd(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: isAdding ? null : onAdd,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                disabledBackgroundColor:
                    AppTheme.primary.withValues(alpha: 100 / 255),
                foregroundColor: Colors.white,
                shadowColor: AppTheme.primary.withValues(alpha: 60 / 255),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 16,
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

class _DesktopSubscriptionListSection extends StatelessWidget {
  final List<Subscription> subscriptions;
  final bool isDark;
  final bool isRefreshing;
  final String? refreshResult;
  final VoidCallback onRefresh;
  final ValueChanged<String> onDelete;

  const _DesktopSubscriptionListSection({
    required this.subscriptions,
    required this.isDark,
    required this.isRefreshing,
    required this.refreshResult,
    required this.onRefresh,
    required this.onDelete,
  });

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
              onPressed: isRefreshing ? null : onRefresh,
              icon: isRefreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primary,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(isRefreshing ? '刷新中...' : '全部刷新'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (refreshResult != null)
          _DesktopSubscriptionRefreshResult(
            message: refreshResult!,
            isDark: isDark,
          ),
        ...subscriptions.map(
          (subscription) => _DesktopSubscriptionCard(
            subscription: subscription,
            isDark: isDark,
            onDelete: () => onDelete(subscription.id),
          ),
        ),
      ],
    );
  }
}

class _DesktopSubscriptionRefreshResult extends StatelessWidget {
  final String message;
  final bool isDark;

  const _DesktopSubscriptionRefreshResult({
    required this.message,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final isSuccess = message.startsWith('成功');
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
              message,
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
}

class _DesktopSubscriptionCard extends StatelessWidget {
  final Subscription subscription;
  final bool isDark;
  final VoidCallback onDelete;

  const _DesktopSubscriptionCard({
    required this.subscription,
    required this.isDark,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                      subscription.name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white : AppTheme.lightTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      LogRedactor.subscriptionUrlForDisplay(subscription.url),
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
                onPressed: onDelete,
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
              _DesktopSubscriptionStatusDot(
                color: subscription.enabled ? AppTheme.success : AppTheme.error,
              ),
              const SizedBox(width: 6),
              Text(
                subscription.enabled ? '已启用' : '已禁用',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      subscription.enabled ? AppTheme.success : AppTheme.error,
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
                subscription.lastUpdate != null
                    ? '更新于 ${_formatDesktopSubscriptionDate(subscription.lastUpdate!)}'
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
}

class _DesktopSubscriptionStatusDot extends StatelessWidget {
  final Color color;

  const _DesktopSubscriptionStatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
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
}

class _DesktopSubscriptionEmptyState extends StatelessWidget {
  final bool isDark;

  const _DesktopSubscriptionEmptyState({required this.isDark});

  @override
  Widget build(BuildContext context) {
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
}

class _DesktopAboutButton extends StatelessWidget {
  final VoidCallback onTap;

  const _DesktopAboutButton({required this.onTap});

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
            border:
                Border.all(color: AppTheme.primary.withValues(alpha: 55 / 255)),
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

class _DesktopAboutInfoPanel extends StatelessWidget {
  final String title;
  final String body;
  final bool isDark;
  final bool accent;

  const _DesktopAboutInfoPanel({
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
        color: isDark
            ? Colors.white.withValues(alpha: 5 / 255)
            : Colors.black.withValues(alpha: 5 / 255),
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
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
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

void _showDesktopSubscriptionAboutDialog(BuildContext context) {
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
                _DesktopAboutInfoPanel(
                  title: '项目地址',
                  body: 'https://github.com/Elegying/SSRVPN',
                  isDark: isDark,
                  accent: true,
                ),
                const SizedBox(height: 12),
                _DesktopAboutInfoPanel(
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
                      backgroundColor: AppTheme.primary
                          .withValues(alpha: (isDark ? 25 : 15) / 255),
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

String _formatDesktopSubscriptionDate(DateTime date) {
  final now = DateTime.now();
  final diff = now.difference(date);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  return '${date.month}/${date.day} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
}

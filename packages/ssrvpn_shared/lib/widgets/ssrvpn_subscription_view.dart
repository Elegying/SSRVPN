import 'package:flutter/material.dart';

import '../models/subscription.dart';
import '../utils/log_redactor.dart';
import 'ssrvpn_app_surface.dart';

class SsrvpnSubscriptionView extends StatelessWidget {
  const SsrvpnSubscriptionView({
    super.key,
    required this.subscriptions,
    required this.urlController,
    required this.isAdding,
    required this.isRefreshing,
    required this.isBusy,
    required this.refreshMessage,
    required this.refreshMessageColor,
    required this.onAdd,
    required this.onRefresh,
    required this.onCancelRefresh,
    required this.onDelete,
  });

  final List<Subscription> subscriptions;
  final TextEditingController urlController;
  final bool isAdding;
  final bool isRefreshing;
  final bool isBusy;
  final String? refreshMessage;
  final Color? refreshMessageColor;
  final VoidCallback onAdd;
  final VoidCallback onRefresh;
  final VoidCallback onCancelRefresh;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding =
              constraints.maxWidth < SsrvpnUiTokens.compactBreakpoint
                  ? 18.0
                  : 28.0;
          return SingleChildScrollView(
            key: const Key('ssrvpn-subscription-scroll'),
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              18,
              horizontalPadding,
              30,
            ),
            child: Center(
              child: ConstrainedBox(
                key: const Key('ssrvpn-subscription-content'),
                constraints: const BoxConstraints(
                  maxWidth: SsrvpnUiTokens.pageMaxWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SubscriptionHeader(),
                    const SizedBox(height: 26),
                    _SubscriptionAddCard(
                      urlController: urlController,
                      isAdding: isAdding,
                      isBusy: isBusy,
                      onAdd: onAdd,
                    ),
                    const SizedBox(height: 30),
                    _SubscriptionListHeader(
                      count: subscriptions.length,
                      isRefreshing: isRefreshing,
                      isBusy: isBusy,
                      onRefresh: onRefresh,
                      onCancelRefresh: onCancelRefresh,
                    ),
                    if (refreshMessage != null) ...[
                      const SizedBox(height: 10),
                      _RefreshMessage(
                        message: refreshMessage!,
                        color: refreshMessageColor ?? SsrvpnUiTokens.primary,
                      ),
                    ],
                    const SizedBox(height: 14),
                    if (subscriptions.isEmpty)
                      const _SubscriptionEmptyState()
                    else
                      ...subscriptions.map(
                        (subscription) => _SubscriptionCard(
                          subscription: subscription,
                          onDelete:
                              isBusy ? null : () => onDelete(subscription.id),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SubscriptionHeader extends StatelessWidget {
  const _SubscriptionHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [SsrvpnUiTokens.primaryBlue, SsrvpnUiTokens.accent],
            ),
            borderRadius: BorderRadius.circular(17),
            boxShadow: const [
              BoxShadow(
                color: Color(0x332F6BFF),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child:
              const Icon(Icons.rss_feed_rounded, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 18),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '订阅管理',
                style: TextStyle(
                  color: SsrvpnUiTokens.textPrimary,
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '支持订阅链接与 ssr:// 导入',
                style: TextStyle(
                  color: SsrvpnUiTokens.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SubscriptionAddCard extends StatelessWidget {
  const _SubscriptionAddCard({
    required this.urlController,
    required this.isAdding,
    required this.isBusy,
    required this.onAdd,
  });

  final TextEditingController urlController;
  final bool isAdding;
  final bool isBusy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SsrvpnSurfaceCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.add_circle_outline_rounded,
                color: SsrvpnUiTokens.accent,
                size: 24,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '添加订阅',
                  style: TextStyle(
                    color: SsrvpnUiTokens.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            key: const Key('ssrvpn-subscription-input'),
            controller: urlController,
            enabled: !isBusy,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: isBusy ? null : (_) => onAdd(),
            decoration: InputDecoration(
              hintText: '粘贴订阅链接或 ssr:// 链接',
              prefixIcon: const Icon(Icons.link_rounded),
              filled: true,
              fillColor: const Color(0xFF181B2A),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 17,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: SsrvpnUiTokens.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: SsrvpnUiTokens.border),
              ),
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('ssrvpn-subscription-add'),
                onPressed: isBusy ? null : onAdd,
                style: FilledButton.styleFrom(
                  backgroundColor: SsrvpnUiTokens.primaryBlue,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      SsrvpnUiTokens.primaryBlue.withValues(alpha: 0.42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
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
                    : const Text(
                        '添加',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionListHeader extends StatelessWidget {
  const _SubscriptionListHeader({
    required this.count,
    required this.isRefreshing,
    required this.isBusy,
    required this.onRefresh,
    required this.onCancelRefresh,
  });

  final int count;
  final bool isRefreshing;
  final bool isBusy;
  final VoidCallback onRefresh;
  final VoidCallback onCancelRefresh;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 9,
          runSpacing: 4,
          children: [
            const Text(
              '我的订阅',
              style: TextStyle(
                color: SsrvpnUiTokens.textPrimary,
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: SsrvpnUiTokens.primaryBlue.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: SsrvpnUiTokens.primaryBlue,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        TextButton.icon(
          onPressed:
              isRefreshing ? onCancelRefresh : (isBusy ? null : onRefresh),
          icon: Icon(
            isRefreshing ? Icons.cancel_outlined : Icons.refresh_rounded,
            size: 20,
          ),
          label: Text(isRefreshing ? '取消刷新' : '全部刷新'),
          style: TextButton.styleFrom(
            foregroundColor: SsrvpnUiTokens.primaryBlue,
          ),
        ),
      ],
    );
  }
}

class _RefreshMessage extends StatelessWidget {
  const _RefreshMessage({required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: '订阅刷新结果：$message',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(message, style: TextStyle(color: color, fontSize: 13)),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.subscription,
    required this.onDelete,
  });

  final Subscription subscription;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SsrvpnSurfaceCard(
        padding: const EdgeInsets.all(18),
        radius: 22,
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1C315E), Color(0xFF173D42)],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.rss_feed_rounded,
                    color: SsrvpnUiTokens.primaryBlue,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: subscription.name,
                        child: Text(
                          subscription.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: SsrvpnUiTokens.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Tooltip(
                        message: LogRedactor.subscriptionUrlForDisplay(
                          subscription.url,
                        ),
                        child: Text(
                          LogRedactor.subscriptionUrlForDisplay(
                            subscription.url,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: SsrvpnUiTokens.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除订阅',
                  onPressed: onDelete,
                  color: SsrvpnUiTokens.error,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: subscription.enabled
                        ? SsrvpnUiTokens.success
                        : SsrvpnUiTokens.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  subscription.enabled ? '已启用' : '已禁用',
                  style: TextStyle(
                    color: subscription.enabled
                        ? SsrvpnUiTokens.success
                        : SsrvpnUiTokens.error,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 18),
                const Icon(
                  Icons.access_time_rounded,
                  size: 15,
                  color: SsrvpnUiTokens.textTertiary,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    _formatUpdateTime(subscription.lastUpdate),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: SsrvpnUiTokens.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionEmptyState extends StatelessWidget {
  const _SubscriptionEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 54),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.rss_feed_rounded,
              size: 52,
              color: SsrvpnUiTokens.textTertiary,
            ),
            SizedBox(height: 14),
            Text(
              '暂无订阅',
              style: TextStyle(
                color: SsrvpnUiTokens.textSecondary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 5),
            Text(
              '在上方粘贴订阅链接开始使用',
              style: TextStyle(color: SsrvpnUiTokens.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatUpdateTime(DateTime? date) {
  if (date == null) return '未更新';
  final difference = DateTime.now().difference(date);
  if (difference.inMinutes < 1) return '更新于刚刚';
  if (difference.inMinutes < 60) return '更新于 ${difference.inMinutes}分钟前';
  if (difference.inHours < 24) return '更新于 ${difference.inHours}小时前';
  if (difference.inDays < 7) return '更新于 ${difference.inDays}天前';
  return '更新于 ${date.month}/${date.day}';
}

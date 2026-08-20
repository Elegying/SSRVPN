import 'dart:async';

import 'package:flutter/material.dart';

import '../models/subscription.dart';
import '../utils/log_redactor.dart';
import '../utils/node_country_policy.dart';
import 'ssrvpn_app_surface.dart';

part 'ssrvpn_subscription_header.dart';
part 'ssrvpn_subscription_connection_card.dart';
part 'ssrvpn_subscription_add_card.dart';

enum SsrvpnSubscriptionConnectionStatus {
  disconnected,
  connecting,
  connected,
}

class SsrvpnSubscriptionView extends StatefulWidget {
  const SsrvpnSubscriptionView({
    super.key,
    required this.subscriptions,
    required this.urlController,
    required this.isAdding,
    required this.isRefreshing,
    required this.isBusy,
    required this.refreshMessage,
    required this.refreshMessageColor,
    this.connectionStatus,
    this.currentNodeName,
    required this.onAdd,
    required this.onRefresh,
    required this.onCancelRefresh,
    required this.onDelete,
    this.onEdit,
  });

  final List<Subscription> subscriptions;
  final TextEditingController urlController;
  final bool isAdding;
  final bool isRefreshing;
  final bool isBusy;
  final String? refreshMessage;
  final Color? refreshMessageColor;
  final SsrvpnSubscriptionConnectionStatus? connectionStatus;
  final String? currentNodeName;
  final VoidCallback onAdd;
  final VoidCallback onRefresh;
  final VoidCallback onCancelRefresh;
  final ValueChanged<String> onDelete;
  final ValueChanged<Subscription>? onEdit;

  @override
  State<SsrvpnSubscriptionView> createState() => _SsrvpnSubscriptionViewState();
}

class _SsrvpnSubscriptionViewState extends State<SsrvpnSubscriptionView> {
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  final _addActionKey = GlobalKey();
  bool _inputFocused = false;
  double _lastViewInset = 0;
  double? _lastViewportHeight;
  Timer? _refreshMessageTimer;
  String? _visibleRefreshMessage;
  Color? _visibleRefreshMessageColor;

  @override
  void initState() {
    super.initState();
    _inputFocusNode.addListener(_handleInputFocus);
    _visibleRefreshMessage = widget.refreshMessage;
    _visibleRefreshMessageColor = widget.refreshMessageColor;
    _scheduleRefreshMessageDismissal();
  }

  @override
  void didUpdateWidget(covariant SsrvpnSubscriptionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshMessage != widget.refreshMessage ||
        oldWidget.refreshMessageColor != widget.refreshMessageColor) {
      _visibleRefreshMessage = widget.refreshMessage;
      _visibleRefreshMessageColor = widget.refreshMessageColor;
      _scheduleRefreshMessageDismissal();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewInset = MediaQuery.viewInsetsOf(context).bottom;
    if (viewInset > 0 && viewInset != _lastViewInset) {
      _ensureAddActionVisible();
    }
    _lastViewInset = viewInset;
  }

  @override
  void dispose() {
    _refreshMessageTimer?.cancel();
    _inputFocusNode.removeListener(_handleInputFocus);
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleRefreshMessageDismissal() {
    _refreshMessageTimer?.cancel();
    _refreshMessageTimer = null;
    if (_visibleRefreshMessage == null) return;
    _refreshMessageTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      setState(() {
        _visibleRefreshMessage = null;
        _visibleRefreshMessageColor = null;
      });
    });
  }

  void _handleInputFocus() {
    _inputFocused = _inputFocusNode.hasFocus;
    if (_inputFocused) _ensureAddActionVisible();
  }

  void _ensureAddActionVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (!_inputFocused && _lastViewInset <= 0)) return;
      final actionContext = _addActionKey.currentContext;
      if (actionContext == null) return;
      Scrollable.ensureVisible(
        actionContext,
        alignment: 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportHeightChanged = _lastViewportHeight != null &&
              constraints.maxHeight != _lastViewportHeight;
          _lastViewportHeight = constraints.maxHeight;
          if (_inputFocused && viewportHeightChanged) {
            _ensureAddActionVisible();
          }
          final horizontalPadding =
              constraints.maxWidth < SsrvpnUiTokens.compactBreakpoint
                  ? 18.0
                  : 28.0;
          return SingleChildScrollView(
            key: const Key('ssrvpn-subscription-scroll'),
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                    if (widget.connectionStatus != null) ...[
                      const SizedBox(height: 20),
                      _SubscriptionConnectionCard(
                        status: widget.connectionStatus!,
                        currentNodeName: widget.currentNodeName,
                      ),
                    ],
                    const SizedBox(height: 26),
                    _SubscriptionAddCard(
                      urlController: widget.urlController,
                      inputFocusNode: _inputFocusNode,
                      addActionKey: _addActionKey,
                      isAdding: widget.isAdding,
                      isBusy: widget.isBusy,
                      onAdd: widget.onAdd,
                    ),
                    const SizedBox(height: 30),
                    _SubscriptionListHeader(
                      count: widget.subscriptions.length,
                      isRefreshing: widget.isRefreshing,
                      isBusy: widget.isBusy,
                      onRefresh: widget.onRefresh,
                      onCancelRefresh: widget.onCancelRefresh,
                    ),
                    if (_visibleRefreshMessage != null) ...[
                      const SizedBox(height: 10),
                      _RefreshMessage(
                        message: _visibleRefreshMessage!,
                        color: _visibleRefreshMessageColor ??
                            SsrvpnUiTokens.primary,
                      ),
                    ],
                    const SizedBox(height: 14),
                    if (widget.subscriptions.isEmpty)
                      const _SubscriptionEmptyState()
                    else
                      ...widget.subscriptions.map(
                        (subscription) => _SubscriptionCard(
                          subscription: subscription,
                          onDelete: widget.isBusy
                              ? null
                              : () => widget.onDelete(subscription.id),
                          onEdit: widget.isBusy || widget.onEdit == null
                              ? null
                              : () => widget.onEdit!(subscription),
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
    required this.onEdit,
  });

  final Subscription subscription;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isMobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final isDesktop = platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        container: true,
        label: subscription.name,
        hint: onEdit == null ? null : (isMobile ? '长按编辑订阅' : '右键编辑订阅'),
        child: GestureDetector(
          key: ValueKey('ssrvpn-subscription-card-${subscription.id}'),
          behavior: HitTestBehavior.opaque,
          onLongPress: isMobile ? onEdit : null,
          onSecondaryTapUp:
              isDesktop && onEdit != null ? (_) => onEdit!() : null,
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
                            triggerMode:
                                isMobile ? TooltipTriggerMode.tap : null,
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
                            triggerMode:
                                isMobile ? TooltipTriggerMode.tap : null,
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

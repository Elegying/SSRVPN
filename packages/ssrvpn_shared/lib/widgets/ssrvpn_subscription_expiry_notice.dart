import 'dart:async';

import 'package:flutter/material.dart';

import '../models/subscription_usage.dart';
import '../utils/statistics_visibility.dart';

/// Advisory only: provider metadata never blocks a connection or renews itself.
class SsrvpnSubscriptionExpiryNotice extends StatefulWidget {
  const SsrvpnSubscriptionExpiryNotice(
      {super.key, required this.usage, required this.active, this.now});
  final SubscriptionUsage? usage;
  final bool active;
  final DateTime Function()? now;

  @override
  State<SsrvpnSubscriptionExpiryNotice> createState() => _ExpiryNoticeState();
}

class _ExpiryNoticeState extends State<SsrvpnSubscriptionExpiryNotice>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didUpdateWidget(SsrvpnSubscriptionExpiryNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(_schedule);
  }

  void _schedule() {
    _timer?.cancel();
    final expiry = widget.usage?.expire;
    if (!widget.active ||
        !statisticsViewIsVisible(WidgetsBinding.instance.lifecycleState) ||
        expiry == null ||
        expiry <= 0) {
      return;
    }
    final remaining = expiry * 1000 - _now.millisecondsSinceEpoch;
    if (remaining <= 0) return;
    _timer = Timer(Duration(milliseconds: remaining.clamp(1, 86400000)), () {
      if (mounted) setState(_schedule);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = widget.usage, now = _now;
    final expiry = usage?.expire;
    if (usage == null ||
        expiry == null ||
        expiry <= 0 ||
        usage.updatedAt.isAfter(now) ||
        now.millisecondsSinceEpoch < expiry * 1000) {
      return const SizedBox.shrink();
    }
    const message = '订阅记录显示账号已到期，请更新订阅或联系服务提供方 [ACCOUNT_EXPIRED]';
    final updated =
        usage.updatedAt.toLocal().toIso8601String().split('.').first;
    return Tooltip(
        message: '$message\n订阅信息更新于 ${updated.replaceFirst('T', ' ')}',
        child: Text(message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall));
  }
}

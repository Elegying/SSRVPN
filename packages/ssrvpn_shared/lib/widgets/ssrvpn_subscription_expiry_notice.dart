import 'dart:async';

import 'package:flutter/material.dart';

import '../models/subscription_usage.dart';
import '../utils/statistics_visibility.dart';

/// Advisory only: provider metadata never blocks a connection or renews itself.
class SsrvpnSubscriptionExpiryNotice extends StatefulWidget {
  const SsrvpnSubscriptionExpiryNotice(
      {super.key,
      required this.usage,
      required this.active,
      this.now,
      this.onDiagnostic});
  final SubscriptionUsage? usage;
  final bool active;
  final ValueChanged<String>? onDiagnostic;
  final DateTime Function()? now;

  @override
  State<SsrvpnSubscriptionExpiryNotice> createState() => _ExpiryNoticeState();
}

class _ExpiryNoticeState extends State<SsrvpnSubscriptionExpiryNotice>
    with WidgetsBindingObserver {
  Timer? _timer;
  (int?, DateTime)? _reported;
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
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final usage = widget.usage;
    final identity = usage == null ? null : (usage.expire, usage.updatedAt);
    if (_reported != identity) _reported = null;
    final expiry = usage?.expire;
    if (!widget.active ||
        !statisticsViewIsVisible(WidgetsBinding.instance.lifecycleState) ||
        expiry == null ||
        expiry <= 0 ||
        usage!.updatedAt.isAfter(_now)) {
      return;
    }
    final remaining = expiry * 1000 - _now.millisecondsSinceEpoch;
    if (remaining <= 0) {
      if (_reported != identity) {
        _reported = identity;
        final updated = usage.updatedAt.toLocal().toIso8601String();
        widget.onDiagnostic?.call('订阅记录显示账号已到期，请更新订阅或联系服务提供方 '
            '[ACCOUNT_EXPIRED]；订阅信息更新于 $updated');
      }
      return;
    }
    _timer = Timer(Duration(milliseconds: remaining.clamp(1, 86400000)), () {
      if (mounted) _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

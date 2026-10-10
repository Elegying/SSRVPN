import '../utils/private_node_latency_policy.dart';
import '../models/subscription_usage.dart';
import 'package:flutter/material.dart';
import '../controllers/account_usage_controller.dart';
import '../models/proxy_node.dart';
import '../services/account_usage_client.dart';
import '../models/vpn_traffic_sample.dart';
import '../utils/statistics_visibility.dart';
import 'ssrvpn_home_traffic_panel.dart';
import 'ssrvpn_home_text.dart';
import 'ssrvpn_subscription_expiry_notice.dart';

/// Account state owns no part of the local sampler's connection lifecycle.
class SsrvpnHomeStatistics extends StatefulWidget {
  const SsrvpnHomeStatistics(
      {super.key,
      required this.active,
      required this.connected,
      required this.node,
      required this.revision,
      required this.readSample,
      this.controller,
      this.subscriptionUsage,
      this.onDiagnostic,
      this.localProxyPort});
  final void Function(String)? onDiagnostic;
  final bool active, connected;
  final ProxyNode? node;
  final Object? revision;
  final Future<VpnTrafficSample?> Function() readSample;
  final AccountUsageController? controller;
  final SubscriptionUsage? subscriptionUsage;
  final int? Function()? localProxyPort;
  @override
  State<SsrvpnHomeStatistics> createState() => _StatisticsState();
}

class _StatisticsState extends State<SsrvpnHomeStatistics>
    with WidgetsBindingObserver {
  late final AccountUsageController _account;
  @override
  void initState() {
    super.initState();
    _account = widget.controller ??
        AccountUsageController(
            onDiagnostic: (message) => widget.onDiagnostic?.call(message),
            fetch: AccountUsageClient(
                localProxyPort: () => widget.localProxyPort?.call()).fetch);
    WidgetsBinding.instance.addObserver(this);
    _update();
  }

  void _update() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _account.update(
        node: widget.node,
        revision: widget.revision,
        active: widget.active && statisticsViewIsVisible(lifecycle));
  }

  @override
  void didUpdateWidget(SsrvpnHomeStatistics oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _update();
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) {
      _account.dispose();
    } else {
      _account.update(node: null, revision: null, active: false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _account,
        builder: (context, _) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              flex: 3,
              child: SsrvpnHomeTrafficPanel(
                  active: widget.active,
                  connected: widget.connected,
                  readSample: widget.readSample,
                  subscriptionUsage:
                      PrivateNodeLatencyPolicy.appliesTo(widget.node)
                          ? null
                          : widget.subscriptionUsage,
                  accountUsage: _account.displayValue,
                  accountStale: _account.isStale,
                  accountStatus: _account.statusMessage == null
                      ? null
                      : _account.isStale
                          ? '上次数据·暂未更新'
                          : _account.value == null
                              ? '暂未更新'
                              : '统计已更新')),
          if (!PrivateNodeLatencyPolicy.appliesTo(widget.node))
            SsrvpnSubscriptionExpiryNotice(
                usage: widget.subscriptionUsage,
                active: widget.active,
                onDiagnostic: widget.onDiagnostic),
          if (_account.deviceLimitNotice case final message?)
            Flexible(
                child: Semantics(
                    liveRegion: true,
                    child: SsrvpnHomeText(message,
                        key: const Key('device-limit-notice'),
                        maxLines: 2,
                        maxFontSize: 14,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall))),
        ]),
      );
}

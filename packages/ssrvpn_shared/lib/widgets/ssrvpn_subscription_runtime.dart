import 'dart:async';
import 'package:flutter/material.dart';
import '../services/clash_service_base.dart';
import 'ssrvpn_subscription_view.dart';

/// One subscription-page status adapter for all platform cores.
class SsrvpnSubscriptionRuntime extends StatefulWidget {
  const SsrvpnSubscriptionRuntime(
      {super.key, required this.core, required this.builder});
  final ClashServiceBase core;
  final Widget Function(
      BuildContext, SsrvpnSubscriptionConnectionStatus, String?) builder;

  @override
  State<SsrvpnSubscriptionRuntime> createState() => _RuntimeState();
}

class _RuntimeState extends State<SsrvpnSubscriptionRuntime> {
  var _status = SsrvpnSubscriptionConnectionStatus.disconnected;
  String? _nodeName;
  var _epoch = 0;

  @override
  void initState() {
    super.initState();
    widget.core.addStatusListener(_changed);
    _sync();
  }

  @override
  void didUpdateWidget(SsrvpnSubscriptionRuntime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.core, widget.core)) return;
    oldWidget.core.removeStatusListener(_changed);
    widget.core.addStatusListener(_changed);
    _sync();
  }

  void _changed() => setState(_sync);

  void _sync() {
    final core = widget.core;
    final epoch = ++_epoch;
    _status = core.isRunning
        ? SsrvpnSubscriptionConnectionStatus.connected
        : core.connectionDesired
            ? SsrvpnSubscriptionConnectionStatus.connecting
            : SsrvpnSubscriptionConnectionStatus.disconnected;
    _nodeName = null;
    if (core.isRunning) unawaited(_readNode(core, epoch));
  }

  Future<void> _readNode(ClashServiceBase core, int epoch) async {
    String? name;
    try {
      name = await core.currentSelectedProxyName();
    } catch (_) {
      // Connection status remains useful even if the advisory node lookup fails.
    }
    if (!mounted ||
        epoch != _epoch ||
        !identical(core, widget.core) ||
        !core.isRunning) {
      return;
    }
    setState(() => _nodeName = name?.trim());
  }

  @override
  void dispose() {
    ++_epoch;
    widget.core.removeStatusListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _status, _nodeName);
}

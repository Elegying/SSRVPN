import 'dart:async';

import 'package:flutter/material.dart';
import 'ssrvpn_app_surface.dart';

import '../models/vpn_traffic_sample.dart';

class SsrvpnHomeTrafficPanel extends StatefulWidget {
  const SsrvpnHomeTrafficPanel({
    super.key,
    required this.active,
    required this.connected,
    required this.readSample,
  });

  final bool active;
  final bool connected;
  final Future<VpnTrafficSample?> Function() readSample;

  @override
  State<SsrvpnHomeTrafficPanel> createState() => _SsrvpnHomeTrafficPanelState();
}

class _SsrvpnHomeTrafficPanelState extends State<SsrvpnHomeTrafficPanel>
    with WidgetsBindingObserver {
  Timer? _timer;
  VpnTrafficSample? _previous;
  double _uploadRate = 0;
  double _downloadRate = 0;
  int _total = 0;
  int _epoch = 0;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restart();
  }

  @override
  void didUpdateWidget(SsrvpnHomeTrafficPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.connected != widget.connected) {
      _restart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(_restart);
  }

  void _restart() {
    _timer?.cancel();
    _previous = null;
    _uploadRate = 0;
    _downloadRate = 0;
    _unavailable = false;
    final epoch = ++_epoch;
    if (!widget.connected) _total = 0;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (widget.active &&
        widget.connected &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      unawaited(_refresh(epoch));
    }
  }

  Future<void> _refresh(int epoch) async {
    try {
      final sample = await widget.readSample();
      if (!mounted || epoch != _epoch) return;
      final rates = sample?.ratesSince(_previous);
      setState(() {
        _previous = sample;
        _uploadRate = rates?.upload ?? 0;
        _downloadRate = rates?.download ?? 0;
        _total = sample?.total ?? 0;
        _unavailable = false;
      });
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _previous = null;
        _unavailable = true;
      });
    }
    if (!mounted || epoch != _epoch) return;
    _timer = Timer(const Duration(seconds: 1), () => _refresh(epoch));
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('home-traffic-panel'),
      padding: const EdgeInsets.only(top: 24),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: SsrvpnUiTokens.pageMaxWidth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _metric('上传速率', _uploadRate, const Color(0xFF64B5FF), '↑ ', true),
              const SizedBox(width: 8),
              _metric(
                  '下载速率', _downloadRate, SsrvpnUiTokens.success, '↓ ', true),
              const SizedBox(width: 8),
              _metric('本次累计', _total, SsrvpnUiTokens.textPrimary, '', false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metric(
      String label, num bytes, Color color, String arrow, bool rate) {
    final value = _unavailable ? '—' : formatVpnTraffic(bytes, rate: rate);
    final parts = value.split(' ');
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    return Expanded(
      child: Semantics(
        label: '$label：${_unavailable ? '暂不可用' : value}',
        excludeSemantics: true,
        child: Container(
          key: ValueKey('home-traffic-card-$label'),
          height: 96 * scale,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: SsrvpnUiTokens.surface.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 18 * scale,
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(label,
                      maxLines: 1,
                      style: const TextStyle(
                        color: SsrvpnUiTokens.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      )),
                ),
              ),
              const Spacer(),
              // Constrain the fitted text's slot, so changing digits or units
              // can never change the card height or move the rest of the page.
              SizedBox(
                height: 26 * scale,
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('$arrow${parts.first}',
                      key: ValueKey('home-traffic-number-$label'),
                      maxLines: 1,
                      style: TextStyle(
                        color: color,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                ),
              ),
              SizedBox(
                height: 18 * scale,
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    parts.length > 1 ? parts.last : ' ',
                    key: ValueKey('home-traffic-unit-$label'),
                    maxLines: 1,
                    style: TextStyle(color: color, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

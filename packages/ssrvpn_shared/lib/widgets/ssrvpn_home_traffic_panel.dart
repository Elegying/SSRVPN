import 'dart:async';
import 'dart:math' as math;
import '../models/account_usage.dart';
import '../utils/account_usage_format.dart';
import 'ssrvpn_home_text.dart';

import 'package:flutter/material.dart';
import 'ssrvpn_app_surface.dart';

import '../models/vpn_traffic_sample.dart';

class SsrvpnHomeTrafficPanel extends StatefulWidget {
  const SsrvpnHomeTrafficPanel({
    super.key,
    required this.active,
    required this.connected,
    required this.readSample,
    this.accountUsage,
  });

  final AccountUsage? accountUsage;
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
    final account = widget.accountUsage;
    String traffic(num value, bool rate) =>
        _unavailable ? '—' : formatVpnTraffic(value, rate: rate);
    final metrics = <({
      String label,
      String number,
      String unit,
      Color color,
      String semantics
    })>[];
    void local(String label, num bytes, Color color, String arrow, bool rate) {
      final value = traffic(bytes, rate);
      final parts = value.split(' ');
      final digits = parts.first.length > 4 && parts.first.endsWith('.0')
          ? parts.first.substring(0, parts.first.length - 2)
          : parts.first;
      metrics.add((
        label: label,
        number: '$arrow$digits',
        unit: parts.length > 1 ? parts.last : ' ',
        color: color,
        semantics: '$label：${_unavailable ? '暂不可用' : value}'
      ));
    }

    local('上传速率', _uploadRate, const Color(0xFF64B5FF), '↑', true);
    local('下载速率', _downloadRate, SsrvpnUiTokens.success, '↓', true);
    local('本次累计', _total, SsrvpnUiTokens.textPrimary, '', false);
    if (account != null) {
      final usage = formatAccountUsage(account);
      final count =
          _devices(account.onlineDevices, compact: true).replaceFirst('约', '');
      final limit =
          _devices(account.deviceLimit, compact: true).replaceFirst('约', '');
      metrics.add((
        label: '已用流量',
        number: usage.amount,
        unit: '${usage.percentage}\n每月1日重置',
        color: SsrvpnUiTokens.textPrimary,
        semantics: '${usage.semantics}。每月1日重置'
      ));
      metrics.add((
        label: '已连接设备',
        number: '$count/$limit',
        unit: account.onlineDevices >= 10000 || account.deviceLimit >= 10000
            ? '约值 · 实例'
            : '客户端实例',
        color: SsrvpnUiTokens.textPrimary,
        semantics:
            '已连接设备：$count，上限 $limit。在线客户端实例 ${account.onlineDevices} 个，上限 ${account.deviceLimit} 个，非物理设备去重数'
      ));
    }
    return LayoutBuilder(
        key: const Key('home-traffic-panel'),
        builder: (context, constraints) {
          final width = math.min(
              constraints.maxWidth, SsrvpnUiTokens.bottomNavigationMaxWidth);
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final gap = constraints.maxHeight < 120 ? 4.0 : 8.0;
          final minimumWidth = 62 + math.min(scale, 2) * 2;
          var columns = width >= minimumWidth * 3 + gap * 2
              ? 3
              : (width >= minimumWidth * 2 + gap ? 2 : 1);
          if (metrics.length == 5 &&
              constraints.maxHeight < 100 &&
              width >= 350 + gap * 4) {
            columns = 5;
          }
          final rows = (metrics.length / columns).ceil();
          final rowBudget = (constraints.maxHeight - gap * (rows - 1)) / rows;
          final cardWidth =
              (width - gap * (columns - 1)) / (columns == 5 ? 6.6 : columns);
          final caption = math
              .min(
                  12 * scale,
                  math.min((cardWidth - 14) / 5,
                      (rowBudget - 13) / (account == null ? 3.74 : 4.84)))
              .clamp(10.0, 24.0);
          final number = math
              .min(math.min(18 * scale, caption * 1.4),
                  (rowBudget - 13) / 1.1 - caption * (account == null ? 2 : 3))
              .clamp(10.0, 34.0);
          final children = <Widget>[];
          for (var start = 0; start < metrics.length; start += columns) {
            if (start != 0) children.add(SizedBox(height: gap));
            final row = metrics.skip(start).take(columns).toList();
            children.add(
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var index = 0; index < row.length; index++) ...[
                if (index != 0) SizedBox(width: gap),
                Expanded(
                    flex: columns == 5
                        ? (row[index].label == '已用流量'
                            ? 20
                            : row[index].label == '已连接设备'
                                ? 16
                                : 10)
                        : 10,
                    child: Semantics(
                      label: row[index].semantics,
                      excludeSemantics: true,
                      child: Container(
                          key:
                              ValueKey('home-traffic-card-${row[index].label}'),
                          padding: EdgeInsets.symmetric(
                              horizontal:
                                  row[index].label == '已用流量' && width < 300
                                      ? 3
                                      : columns == 5
                                          ? 5
                                          : 6,
                              vertical: columns == 5
                                  ? 0
                                  : constraints.maxHeight < 120
                                      ? 2
                                      : 4),
                          decoration: BoxDecoration(
                              color:
                                  SsrvpnUiTokens.surface.withValues(alpha: .78),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: .06))),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SsrvpnHomeText(row[index].label,
                                    lineHeight: row[index].label == '已用流量' &&
                                            constraints.maxHeight < 120
                                        ? 1
                                        : 1.1,
                                    maxFontSize: caption,
                                    style: TextStyle(
                                        letterSpacing: 0,
                                        color: SsrvpnUiTokens.textSecondary,
                                        fontSize: caption)),
                                SsrvpnHomeText(
                                    columns == 5 && row[index].label == '已用流量'
                                        ? row[index]
                                            .number
                                            .replaceFirst('/', '/\n')
                                        : row[index].number,
                                    maxLines: columns == 5 &&
                                            row[index].label == '已用流量'
                                        ? 2
                                        : 1,
                                    fitReference: row[index].label == '已连接设备'
                                        ? '9999/9999'
                                        : row[index].label == '已用流量'
                                            ? (columns == 5
                                                ? '1023MB/\n1023MB'
                                                : '1023MB/1023MB')
                                            : '↑9999',
                                    key: ValueKey(
                                        'home-traffic-number-${row[index].label}'),
                                    lineHeight: row[index].label == '已用流量' &&
                                            constraints.maxHeight < 120
                                        ? 1
                                        : 1.1,
                                    maxFontSize: columns == 5 &&
                                            row[index].label == '已用流量'
                                        ? 10
                                        : number,
                                    style: TextStyle(
                                        letterSpacing: 0,
                                        color: row[index].color,
                                        fontSize: number,
                                        fontWeight: FontWeight.w600,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures()
                                        ])),
                                SsrvpnHomeText(row[index].unit,
                                    maxLines:
                                        row[index].label == '已用流量' ? 2 : 1,
                                    fitReference: row[index].label == '已连接设备'
                                        ? '约值 · 实例'
                                        : row[index].label == '已用流量'
                                            ? '9.22e+20%\n每月1日重置'
                                            : '999E',
                                    key: ValueKey(
                                        'home-traffic-unit-${row[index].label}'),
                                    lineHeight: row[index].label == '已用流量' &&
                                            constraints.maxHeight < 120
                                        ? 1
                                        : 1.1,
                                    maxFontSize: caption,
                                    style: TextStyle(
                                        letterSpacing: 0,
                                        color: row[index].color,
                                        fontSize: caption)),
                              ])),
                    )),
              ],
            ]));
          }
          return Center(
              heightFactor: 1,
              child: SizedBox(
                  width: width,
                  child: Column(
                      mainAxisSize: MainAxisSize.min, children: children)));
        });
  }

  String _devices(int count, {bool compact = false}) {
    if (count < 10000) return '$count';
    const units = ['K', 'M', 'G', 'T', 'P', 'E'];
    var value = count / 1000;
    var index = 0;
    while (value >= 999.5 && index < units.length - 1) {
      value /= 1000;
      index++;
    }
    return '约${value.toStringAsFixed(compact || value >= 99.95 ? 0 : 1)}${units[index]}';
  }
}

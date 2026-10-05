import 'package:flutter/material.dart';
import '../models/account_usage.dart';
import 'ssrvpn_home_text.dart';
import 'ssrvpn_pixel_surface.dart';
import 'ssrvpn_statistics_fit.dart';
import 'ssrvpn_theme_icon.dart';
import 'ssrvpn_themed_statistics.dart' show SsrvpnMetric;
import 'ssrvpn_usage_ring.dart';

/// Pixel reference layout, retaining live quota and device ownership semantics.
class SsrvpnPixelStatistics extends StatelessWidget {
  const SsrvpnPixelStatistics({super.key, required this.metrics, this.account});
  final List<SsrvpnMetric> metrics;
  final AccountUsage? account;
  static const _cream = Color(0xFFEBDCB5), _ink = Color(0xFF153A2A);
  Widget _text(String value, double size, Color color) => SsrvpnHomeText(value,
      maxFontSize: size,
      style:
          TextStyle(fontSize: size, color: color, fontWeight: FontWeight.w700));
  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.2);
    final known = account != null && account!.trafficLimitBytes > 0;
    final progress = known
        ? (account!.usedBytes / account!.trafficLimitBytes).clamp(0.0, 1.0)
        : 0.0;
    return SsrvpnStatisticsFit(
        naturalHeight: (metrics.length > 3 ? 202 : 78) * scale,
        child: Column(key: const Key('home-traffic-panel'), children: [
          SsrvpnPixelSurface(
              color: const Color(0xFF102D25),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0)
                    Container(
                        width: 1,
                        height: 38 * scale,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        color: const Color(0xFF496B52)),
                  Expanded(
                      child: Semantics(
                          label: metrics[i].semantics,
                          excludeSemantics: true,
                          child: Row(children: [
                            SsrvpnThemeIcon(['upload', 'download', 'total'][i],
                                fallback: [
                                  Icons.arrow_upward,
                                  Icons.arrow_downward,
                                  Icons.storage
                                ][i],
                                size: 24,
                                color: _cream),
                            const SizedBox(width: 5),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  _text(metrics[i].label, 10, _cream),
                                  const SizedBox(height: 5),
                                  _text(
                                      '${metrics[i].number.replaceFirst(RegExp(r"^[↑↓]"), "")} ${metrics[i].unit}',
                                      16,
                                      const Color(0xFFFAF7EB)),
                                ])),
                          ]))),
                ]
              ])),
          if (metrics.length > 3) ...[
            const SizedBox(height: 8),
            SsrvpnPixelSurface(
                color: _cream,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                child: SizedBox(
                    height: 82 * scale,
                    child: Column(children: [
                      Expanded(
                          child: Semantics(
                              label: metrics[3].semantics,
                              excludeSemantics: true,
                              child: SsrvpnUsageRing(
                                  account: account,
                                  foregroundColor: _ink,
                                  progressColor: const Color(0xFF246347),
                                  child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _text('已用 ${metrics[3].number}', 16,
                                            _ink),
                                        const SizedBox(height: 8),
                                        SizedBox(
                                            height: 10,
                                            child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                    color:
                                                        const Color(0xFF183D2B),
                                                    border: Border.all(
                                                        color: _ink, width: 2)),
                                                child: Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: FractionallySizedBox(
                                                        widthFactor: progress,
                                                        child: const ColoredBox(
                                                            color: Color(
                                                                0xFF7BAD75),
                                                            child: SizedBox
                                                                .expand()))))),
                                      ])))),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(
                            child: _text(
                                metrics[3].unit, 9, const Color(0xFF50664A))),
                        if (metrics.length > 4)
                          Expanded(
                              flex: 2,
                              child: Semantics(
                                  label: metrics[4].semantics,
                                  excludeSemantics: true,
                                  child: Row(children: [
                                    SsrvpnThemeIcon('devices',
                                        fallback: Icons.devices,
                                        size: 15,
                                        color: _ink),
                                    const SizedBox(width: 4),
                                    Expanded(
                                        child: _text(
                                            '已连接设备 ${metrics[4].number}',
                                            10,
                                            _ink))
                                  ]))),
                      ]),
                    ]))),
          ],
        ]));
  }
}

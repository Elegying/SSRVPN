import 'ssrvpn_statistics_fit.dart';
import 'ssrvpn_pixel_statistics.dart';
import '../models/app_settings.dart';
import 'package:flutter/material.dart';
import '../models/account_usage.dart';
import 'ssrvpn_theme.dart';
import 'ssrvpn_illustrated_surface.dart';
import 'ssrvpn_theme_icon.dart';
import 'ssrvpn_themed_statistics.dart' show SsrvpnMetric;
import 'ssrvpn_home_text.dart';
import 'ssrvpn_usage_ring.dart';

/// The reference traffic panel, with the real private-account and device metrics.
class SsrvpnIllustratedStatistics extends StatelessWidget {
  const SsrvpnIllustratedStatistics(
      {super.key, required this.metrics, required this.account});
  final List<SsrvpnMetric> metrics;
  final AccountUsage? account;
  @override
  Widget build(BuildContext context) {
    final t = SsrvpnTheme.of(context);
    if (t.variant == AppThemeVariant.pixel &&
        !MediaQuery.highContrastOf(context)) {
      return SsrvpnPixelStatistics(metrics: metrics, account: account);
    }
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.2);
    Widget text(String s, double size, {bool bold = false}) => SsrvpnHomeText(s,
        maxFontSize: size,
        style: TextStyle(
            fontSize: size,
            color: t.textPrimary,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500));
    Widget label(String icon, IconData fallback, String title) =>
        Row(children: [
          SsrvpnThemeIcon(icon, fallback: fallback, size: 20, color: t.primary),
          const SizedBox(width: 5),
          Expanded(child: text(title, 11)),
        ]);
    return SsrvpnStatisticsFit(
        naturalHeight: (metrics.length > 3 ? 160 : 70) * scale +
            (t.variant == AppThemeVariant.pixel ? 12 : 0),
        child: Column(
            key: const Key('home-traffic-panel'),
            mainAxisSize: MainAxisSize.min,
            children: [
              SsrvpnIllustratedSurface(
                  radius: 18,
                  padding: const EdgeInsets.all(10),
                  child: Row(children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                          child: Semantics(
                              label: metrics[i].semantics,
                              excludeSemantics: true,
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    label(
                                        ['upload', 'download', 'total'][i],
                                        [
                                          Icons.arrow_upward,
                                          Icons.arrow_downward,
                                          Icons.data_usage
                                        ][i],
                                        metrics[i].label),
                                    const SizedBox(height: 5),
                                    text(
                                        '${metrics[i].number.replaceFirst(RegExp(r"^[↑↓]"), "")} ${metrics[i].unit}',
                                        17,
                                        bold: true),
                                  ]))),
                    ]
                  ])),
              if (metrics.length > 3) ...[
                const SizedBox(height: 8),
                SsrvpnIllustratedSurface(
                    radius: 18,
                    padding: const EdgeInsets.all(10),
                    child: SizedBox(
                        height: 61 * scale,
                        child: Row(children: [
                          Expanded(
                              flex: 3,
                              child: Semantics(
                                  label: metrics[3].semantics,
                                  excludeSemantics: true,
                                  child: SsrvpnUsageRing(
                                      account: account,
                                      child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            text('已用流量', 11),
                                            const SizedBox(height: 3),
                                            text(metrics[3].number, 16,
                                                bold: true),
                                            const SizedBox(height: 3),
                                            text(metrics[3].unit, 9),
                                          ])))),
                          if (metrics.length > 4) ...[
                            VerticalDivider(width: 14, color: t.border),
                            Expanded(
                                flex: 2,
                                child: Semantics(
                                    label: metrics[4].semantics,
                                    excludeSemantics: true,
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Row(children: [
                                            SsrvpnThemeIcon('devices',
                                                fallback: Icons.devices,
                                                size: 20,
                                                color: t.textPrimary),
                                            const SizedBox(width: 5),
                                            Expanded(child: text('已连接设备', 11))
                                          ]),
                                          const SizedBox(height: 3),
                                          text(metrics[4].number, 20,
                                              bold: true),
                                          text(metrics[4].unit, 9),
                                        ]))),
                          ]
                        ]))),
              ],
            ]));
  }
}

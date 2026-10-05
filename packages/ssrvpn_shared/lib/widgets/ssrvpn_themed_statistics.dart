import 'ssrvpn_statistics_fit.dart';
import 'ssrvpn_illustrated_statistics.dart';
import 'package:flutter/material.dart';
import '../models/account_usage.dart';
import '../models/app_settings.dart';
import 'ssrvpn_theme.dart';
import 'ssrvpn_soft_surface.dart';
import 'ssrvpn_home_text.dart';
import 'ssrvpn_usage_ring.dart';
import 'ssrvpn_theme_icon.dart';

typedef SsrvpnMetric = ({
  String label,
  String number,
  String unit,
  Color color,
  String semantics
});

class SsrvpnThemedStatistics extends StatelessWidget {
  const SsrvpnThemedStatistics(
      {super.key, required this.metrics, required this.account});
  final List<SsrvpnMetric> metrics;
  final AccountUsage? account;
  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    if (theme.isIllustrated) {
      return SsrvpnIllustratedStatistics(metrics: metrics, account: account);
    }
    final cloud = theme.variant == AppThemeVariant.cloud || theme.isSoft;
    final sakura = theme.variant == AppThemeVariant.sakura;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.2);
    Widget number(SsrvpnMetric m, double size) =>
        SsrvpnHomeText(m.number.replaceFirst(RegExp(r'^[↑↓]'), ''),
            key: ValueKey('home-traffic-number-${m.label}'),
            maxFontSize: size,
            minFontSize: 12,
            style: TextStyle(
                color: theme.textPrimary,
                fontSize: size,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()]));
    Widget frame(Widget child, {bool card = false, Color? color}) => Container(
        padding: const EdgeInsets.all(9),
        decoration: theme.isSoft && !MediaQuery.highContrastOf(context)
            ? ssrvpnSoftDecoration(radius: 24)
            : BoxDecoration(
                color: card
                    ? (theme.isSoft ? theme.surface : color ?? theme.surface)
                    : null,
                borderRadius: BorderRadius.circular(cloud ? 22 : 18),
                border: card && !theme.isSoft
                    ? Border.all(
                        color: cloud ? Colors.white : theme.border, width: 1.3)
                    : null,
                boxShadow: cloud
                    ? [
                        BoxShadow(
                            color:
                                const Color(0xFFBAA776).withValues(alpha: .13),
                            blurRadius: 18,
                            offset: const Offset(0, 7))
                      ]
                    : null),
        child: child);
    final icons = [
      Icons.arrow_upward_rounded,
      Icons.arrow_downward_rounded,
      Icons.pie_chart_outline_rounded
    ];
    return SsrvpnStatisticsFit(
        naturalHeight: (theme.isSoft ? 80 : 72) * scale +
            (!cloud ? 10 : 0) +
            (metrics.length > 3
                ? (cloud || sakura ? (theme.isSoft ? 14 : 10) : 16) + 86 * scale
                : 0),
        child: Column(
            key: const Key('home-traffic-panel'),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!cloud) Divider(height: 10, color: theme.border),
              SizedBox(
                  height: (theme.isSoft ? 80 : 72) * scale,
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < 3; i++) ...[
                          if (i > 0)
                            cloud
                                ? SizedBox(width: theme.isSoft ? 12 : 7)
                                : VerticalDivider(
                                    width: 9,
                                    color: theme.border,
                                    indent: 8,
                                    endIndent: 8),
                          Expanded(
                              child: Semantics(
                                  label: metrics[i].semantics,
                                  excludeSemantics: true,
                                  child: frame(
                                      Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  SsrvpnThemeIcon(
                                                      [
                                                        'upload',
                                                        'download',
                                                        'total'
                                                      ][i],
                                                      fallback: icons[i],
                                                      color: metrics[i].color,
                                                      size: 20),
                                                  const SizedBox(width: 4),
                                                  Flexible(
                                                      child: SsrvpnHomeText(
                                                          metrics[i].label,
                                                          maxFontSize: 11,
                                                          style: TextStyle(
                                                              color: theme
                                                                  .textSecondary,
                                                              fontSize: 11))),
                                                ]),
                                            const SizedBox(height: 7),
                                            Flexible(
                                                child: FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    child: Text.rich(
                                                        TextSpan(children: [
                                                      TextSpan(
                                                          text: metrics[i]
                                                              .number
                                                              .replaceFirst(
                                                                  RegExp(
                                                                      r'^[↑↓]'),
                                                                  ''),
                                                          style: TextStyle(
                                                              color: theme
                                                                  .textPrimary,
                                                              fontSize: 22,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              fontFeatures: const [
                                                                FontFeature
                                                                    .tabularFigures()
                                                              ])),
                                                      TextSpan(
                                                          text:
                                                              ' ${metrics[i].unit}',
                                                          style: TextStyle(
                                                              color: theme
                                                                  .textSecondary,
                                                              fontSize: 11)),
                                                    ])))),
                                          ]),
                                      card: cloud,
                                      color: [
                                        const Color(0xFFF0F8FF),
                                        const Color(0xFFF1FCF6),
                                        const Color(0xFFFFFAEC)
                                      ][i]))),
                        ]
                      ])),
              if (metrics.length > 3) ...[
                cloud || sakura
                    ? SizedBox(height: theme.isSoft ? 14 : 10)
                    : Divider(height: 16, color: theme.border),
                SizedBox(
                    height: 86 * scale,
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                              flex: 3,
                              child: Semantics(
                                  label: metrics[3].semantics,
                                  excludeSemantics: true,
                                  child: frame(
                                      SsrvpnUsageRing(
                                          account: account,
                                          child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text('已用流量',
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: theme
                                                            .textSecondary)),
                                                const SizedBox(height: 5),
                                                number(metrics[3], 19),
                                                const SizedBox(height: 4),
                                                Text(
                                                    account == null
                                                        ? '暂未更新'
                                                        : '每月1日重置',
                                                    style: TextStyle(
                                                        fontSize: 9,
                                                        color: theme
                                                            .textSecondary)),
                                              ])),
                                      card: cloud || sakura))),
                          cloud || sakura
                              ? SizedBox(width: theme.isSoft ? 12 : 7)
                              : VerticalDivider(width: 14, color: theme.border),
                          if (metrics.length > 4)
                            Expanded(
                                flex: 2,
                                child: Semantics(
                                    label: metrics[4].semantics,
                                    excludeSemantics: true,
                                    child: frame(
                                        Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(children: [
                                                SsrvpnThemeIcon('devices',
                                                    fallback:
                                                        Icons.devices_rounded,
                                                    color: theme.accent,
                                                    size: 22),
                                                const SizedBox(width: 4),
                                                Expanded(
                                                    child: SsrvpnHomeText(
                                                        '已连接设备',
                                                        maxFontSize: 12,
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: theme
                                                                .textSecondary)))
                                              ]),
                                              const SizedBox(height: 5),
                                              number(metrics[4], 23),
                                              Text(metrics[4].unit,
                                                  style: TextStyle(
                                                      fontSize: 9,
                                                      color:
                                                          theme.textSecondary)),
                                            ]),
                                        card: cloud || sakura))),
                        ])),
              ],
            ]));
  }
}

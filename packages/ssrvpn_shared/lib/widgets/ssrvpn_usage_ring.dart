import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/account_usage.dart';
import '../utils/account_usage_format.dart';
import 'ssrvpn_theme.dart';

/// A determinate account gauge; unknown or zero allowance never implies 0%.
class SsrvpnUsageRing extends StatelessWidget {
  const SsrvpnUsageRing(
      {super.key,
      required this.account,
      required this.child,
      this.compact = false,
      this.foregroundColor,
      this.progressColor});
  final AccountUsage? account;
  final Color? foregroundColor, progressColor;
  final bool compact;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final colors = SsrvpnTheme.of(context);
        final size = math.min(compact && box.maxWidth < 190 ? 24.0 : 52.0,
            math.min(box.maxHeight, box.maxWidth * .29));
        final usage = account;
        final known = usage != null && usage.trafficLimitBytes > 0;
        final progress = known
            ? (usage.usedBytes / usage.trafficLimitBytes).clamp(0.0, 1.0)
            : 0.0;
        final percentage =
            usage == null ? '—' : formatAccountUsage(usage).percentage;
        return Row(children: [
          SizedBox(
              width: size,
              height: size,
              child: Stack(alignment: Alignment.center, children: [
                Positioned.fill(
                    child: Semantics(
                  // Account usage is not bounded to a progress bar's 0–100.
                  label: '已用流量',
                  value: known ? percentage : '百分比暂不可用',
                  excludeSemantics: true,
                  child: CircularProgressIndicator(
                    key: const Key('account-usage-ring'),
                    value: progress,
                    strokeWidth: (size * .12).clamp(2.0, 6.0),
                    strokeCap: StrokeCap.round,
                    color: progressColor ?? colors.primary,
                    backgroundColor: (progressColor ?? colors.primary)
                        .withValues(alpha: .17),
                  ),
                )),
                if (size >= 40)
                  SizedBox(
                    width: size * .72,
                    height: size * .65,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                          percentage.length > 4
                              ? percentage.replaceFirst('%', '\n%')
                              : percentage,
                          key: const Key('account-usage-percentage'),
                          textAlign: TextAlign.center,
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                              fontSize: 10,
                              height: 1.0,
                              fontWeight: FontWeight.w700,
                              color: foregroundColor ?? colors.textPrimary)),
                    ),
                  ),
              ])),
          SizedBox(width: math.min(6, box.maxWidth * .025)),
          Expanded(child: child),
        ]);
      });
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/vpn_traffic_sample.dart';

typedef SsrvpnMetric = ({
  String label,
  String number,
  String unit,
  Color color,
  String semantics
});

typedef SsrvpnMetricValue = ({String number, String unit, String semantics});

SsrvpnMetricValue ssrvpnTrafficValue(
    String label, num bytes, String arrow, bool rate,
    {bool unavailable = false}) {
  final value = unavailable ? '—' : formatVpnTraffic(bytes, rate: rate);
  final parts = value.split(' ');
  final digits = parts.first.length > 4 && parts.first.endsWith('.0')
      ? parts.first.substring(0, parts.first.length - 2)
      : parts.first;
  return (
    number: '$arrow$digits',
    unit: parts.length > 1 ? parts.last : ' ',
    semantics: '$label：${unavailable ? '暂不可用' : value}'
  );
}

/// Updates one metric only when its displayed value or semantics change.
/// Static account cards and surrounding layout never listen to traffic ticks.
class SsrvpnMetricBuilder extends StatelessWidget {
  const SsrvpnMetricBuilder({
    super.key,
    required this.metric,
    required this.builder,
    this.value,
  });

  final SsrvpnMetric metric;
  final ValueListenable<SsrvpnMetricValue>? value;
  final Widget Function(BuildContext, SsrvpnMetric) builder;

  @override
  Widget build(BuildContext context) => value == null
      ? builder(context, metric)
      : ValueListenableBuilder<SsrvpnMetricValue>(
          valueListenable: value!,
          builder: (context, data, _) => builder(context, (
            label: metric.label,
            color: metric.color,
            number: data.number,
            unit: data.unit,
            semantics: data.semantics
          )),
        );
}

import 'package:flutter/material.dart';
import '../models/subscription_usage.dart';
import 'ssrvpn_themed_statistics.dart' show SsrvpnMetric;

String _bytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2)} ${units[i]}';
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String subscriptionUsageUpdateLabel(SubscriptionUsage usage) {
  final date = usage.updatedAt.toLocal();
  return '更新于 ${_date(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}；订阅账号用量，随订阅刷新更新';
}

List<SsrvpnMetric> subscriptionUsageMetrics(
    SubscriptionUsage usage, Color color) {
  final result = <SsrvpnMetric>[];
  final used = usage.used;
  final note = subscriptionUsageUpdateLabel(usage);
  if (used != null) {
    final amount =
        '${_bytes(used)}${usage.total == null ? '' : usage.total == 0 ? ' / 不限量' : ' / ${_bytes(usage.total!)}'}';
    result.add((
      label: '已用流量',
      number: amount,
      unit: '订阅账号用量',
      color: color,
      semantics: '已用流量：$amount。$note'
    ));
  }
  final expire = usage.expire;
  if (expire != null) {
    final date = expire == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expire * 1000).toLocal();
    final expired = date != null && !date.isAfter(DateTime.now());
    final number = date == null ? '长期有效' : _date(date);
    result.add((
      label: '到期时间',
      number: number,
      unit: expired
          ? '已到期'
          : date == null
              ? '未设到期时间'
              : '本地时间',
      color: color,
      semantics:
          '到期时间：${date?.toString() ?? number}。${expired ? '已到期。' : ''}$note'
    ));
  }
  return result;
}

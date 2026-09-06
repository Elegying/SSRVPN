import '../models/account_usage.dart';
import '../models/vpn_traffic_sample.dart';

/// Presentation only: both counters come from the same validated response.
({String amount, String percentage, String semantics}) formatAccountUsage(
    AccountUsage usage) {
  String bytes(int value) =>
      formatVpnTraffic(value).replaceFirst('.0 ', ' ').replaceAll(' ', '');
  final used = bytes(usage.usedBytes);
  final limit = bytes(usage.trafficLimitBytes);
  final percent = usage.trafficLimitBytes == 0
      ? null
      : usage.usedBytes / usage.trafficLimitBytes * 100;
  final percentage = percent == null
      ? '—%'
      : percent > 0 && percent < .1
          ? '${percent.toStringAsFixed(2)}%'
          : percent >= 10000
              ? '${percent.toStringAsExponential(1).replaceFirst('e+', 'e')}%'
              : '${percent.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}%';
  return (
    amount: '$used/$limit',
    percentage: percentage,
    semantics: '已用流量：$used/$limit $percentage，账号全部受管节点合计。'
        '已用 ${usage.usedBytes} 字节，额度 ${usage.trafficLimitBytes} 字节'
        '${percent == null ? '，零额度，百分比不适用' : ''}'
  );
}

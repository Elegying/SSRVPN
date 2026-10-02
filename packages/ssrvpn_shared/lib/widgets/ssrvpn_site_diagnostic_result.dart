import 'package:flutter/material.dart';
import '../models/site_diagnostic_report.dart';

class SsrvpnSiteDiagnosticResult extends StatelessWidget {
  const SsrvpnSiteDiagnosticResult({super.key, required this.report});
  final SiteDiagnosticReport report;
  @override
  Widget build(BuildContext context) {
    final route = report.route;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Semantics(
          liveRegion: true,
          child: Text(report.summary,
              style: Theme.of(context).textTheme.titleMedium)),
      const SizedBox(height: 16),
      _section(
          context,
          '实际访问路径',
          route == null
              ? '${report.host} → 路由未捕获\n连接可能在路由记录生成前失败；不会用选中节点代替实际出口。'
              : '${report.host}\n匹配规则：${route.rule}\n出口：${route.path}\n依据：${route.fromLog ? '本次请求的内核日志' : '本次请求的内核连接记录'}'),
      if (report.reference != null)
        _section(context, '参考站点对比',
            '${report.reference!.host}：${report.reference!.summary}\n出口：${report.reference!.route?.path ?? '未捕获，不能视为同一路径'}'),
      _section(context, '问题判断', report.assessment),
      _section(context, '下一步', report.advice),
    ]);
  }

  Widget _section(BuildContext context, String title, String content) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(content),
          ]));
}

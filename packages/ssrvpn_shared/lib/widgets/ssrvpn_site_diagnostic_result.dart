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
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
                report.succeeded
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                color: report.succeeded
                    ? Colors.lightGreenAccent
                    : Colors.orangeAccent),
            const SizedBox(width: 8),
            Expanded(
                child: Text(report.verdict,
                    style: Theme.of(context).textTheme.titleMedium)),
          ])),
      const SizedBox(height: 16),
      _section(
          context,
          '实际访问路径',
          route == null
              ? '${report.host} → 路由未捕获\n连接可能在路由记录生成前失败；不会用选中节点代替实际出口。'
              : '${report.host}\n匹配规则：${route.ruleLabel}\n出口：${route.path}'),
      if (report.redirects.isNotEmpty)
        _section(
            context,
            '网站跳转过程',
            [...report.redirects, report]
                .map((step) => '${step.host}（${step.route?.path ?? '路径未捕获'}）')
                .join(' → ')),
      if (report.reference != null)
        _section(context, '参考站点对比',
            '${report.reference!.host}：${report.reference!.verdict}\n出口：${report.reference!.route?.path ?? '未捕获，不能视为同一路径'}'),
      _section(context, '问题判断', report.assessment),
      _section(context, '下一步', report.advice),
      ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('技术详情'),
          children: [
            for (final step in [...report.redirects, report])
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('${step.host}：${step.summary}'))
          ]),
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

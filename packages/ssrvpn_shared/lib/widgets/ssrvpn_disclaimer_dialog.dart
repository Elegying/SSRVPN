import 'package:flutter/material.dart';
import 'ssrvpn_info_dialog.dart';

Future<void> showSsrvpnDisclaimerDialog(BuildContext context) =>
    showSsrvpnInfoDialog(
      context,
      panelKey: const Key('ssrvpn-disclaimer-glass'),
      scrollKey: const Key('ssrvpn-disclaimer-scroll'),
      icon: Icons.info_outline_rounded,
      title: '免责声明',
      content: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Section(
              '1',
              '软件性质',
              '本软件是基于 Clash.Meta（mihomo）内核的开源网络代理客户端，仅提供配置管理、规则分流与流量转发等本地工具功能。\n\n'
                  '本软件自身不提供任何代理服务器、节点、订阅、机场或网络接入服务，也不与任何此类服务的提供者存在合作、代理或担保关系。'),
          _Section(
              '2',
              '使用限制',
              '本软件仅供学习交流、技术研究等非商业用途，严禁将本软件用于任何商业目的，包括但不限于付费分发、捆绑销售、作为商业服务的组成部分或以本软件名义开展经营活动；任何商业行为与本软件及其开发者无关。\n\n'
                  '严禁将本软件用于违反你所在国家或地区法律法规的活动，包括但不限于绕过依法设置的网络访问限制、传播违法信息、实施网络攻击或侵犯他人合法权益。'),
          _Section('3', '用户责任',
              '你应自行确认使用本软件在你所在国家或地区是合法的，并对使用本软件的全部行为及其后果独立承担法律责任。'),
        ],
      ),
    );

class _Section extends StatelessWidget {
  const _Section(this.number, this.title, this.text);
  final String number, title, text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            ExcludeSemantics(
              child: CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                foregroundColor: theme.colorScheme.onSurface,
                child: Text(number),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Text(text,
              style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.6)),
        ],
      ),
    );
  }
}

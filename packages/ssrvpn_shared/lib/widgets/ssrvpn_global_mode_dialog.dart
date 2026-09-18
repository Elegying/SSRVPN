import 'package:flutter/material.dart';

import 'ssrvpn_info_dialog.dart';

Future<bool> showSsrvpnGlobalModeDialog(BuildContext context) async {
  var confirmed = false;
  await showSsrvpnInfoDialog(
    context,
    panelKey: const Key('ssrvpn-global-mode-glass'),
    scrollKey: const Key('ssrvpn-global-mode-scroll'),
    icon: Icons.warning_amber_rounded,
    title: '全局模式提醒',
    content: const Text(
      '全局模式下，进入客户端的流量默认通过当前节点访问，可能影响国内服务速度并增加节点流量消耗。安卓国内应用绕过名单、应用分流和手动规则仍按原有优先级生效；系统代理模式仅影响遵循代理设置的应用。若只是个别网站打不开，可以先使用【强制代理网站】。',
      style: TextStyle(fontSize: 14, height: 1.5),
    ),
    buttonLabel: '确定',
    onConfirm: () => confirmed = true,
  );
  return confirmed;
}

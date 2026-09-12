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
      '注意⚠️：全局模式会代理设备所有流量，会导致国内服务访问缓慢和流量消耗过快，如有网站在智能模式下无法访问的情况，可以使用本软件的【强制代理网站】功能',
      style: TextStyle(fontSize: 14, height: 1.5),
    ),
    buttonLabel: '确定',
    onConfirm: () => confirmed = true,
  );
  return confirmed;
}

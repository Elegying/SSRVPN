import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';
import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../services/update_checker.dart';
import 'ssrvpn_info_dialog.dart';

Future<void> showSsrvpnAboutDialog(
  BuildContext context, {
  Future<String?> Function()? onCheckForUpdate,
}) {
  return showSsrvpnInfoDialog(
    context,
    panelKey: const Key('ssrvpn-about-glass'),
    scrollKey: const Key('ssrvpn-about-scroll'),
    icon: Icons.vpn_lock_rounded,
    title: '关于 SSRVPN',
    content: Builder(
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colors = theme.colorScheme;
        final secondaryText = colors.onSurfaceVariant;
        final accentText = theme.brightness == Brightness.dark
            ? Color.lerp(colors.primary, Colors.white, 0.40)!
            : Color.lerp(colors.primary, Colors.black, 0.16)!;
        final thirdPartyUrl =
            'https://github.com/Elegying/SSRVPN/tree/v${AppConstants.appVersion}/third_party';
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '版本 ${AppConstants.appVersion}',
              style: TextStyle(color: accentText),
            ),
            if (onCheckForUpdate != null) ...[
              const SizedBox(height: 12),
              _AboutUpdateCheck(onCheck: onCheckForUpdate),
            ],
            const SizedBox(height: 16),
            const Text(
              '项目地址',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            SelectableText(
              'https://github.com/Elegying/SSRVPN',
              style: TextStyle(color: accentText),
            ),
            const SizedBox(height: 16),
            const Text(
              '第三方许可与对应源码',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            SelectableText(
              thirdPartyUrl,
              style: TextStyle(color: accentText),
            ),
            const SizedBox(height: 16),
            const Text(
              '免责声明',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '本软件仅供学习与研究使用，请遵守当地法律法规。\n'
              '使用者应对自身行为承担全部责任。\n'
              '开发者不对因使用本软件产生的任何后果负责。',
              style: TextStyle(color: secondaryText, height: 1.45),
            ),
            const SizedBox(height: 16),
            Text(
              '开发者：Elegying（两颗西柚）',
              style: TextStyle(color: secondaryText),
            ),
          ],
        );
      },
    ),
  );
}

class _AboutUpdateCheck extends StatefulWidget {
  const _AboutUpdateCheck({required this.onCheck});

  final Future<String?> Function() onCheck;

  @override
  State<_AboutUpdateCheck> createState() => _AboutUpdateCheckState();
}

class _AboutUpdateCheckState extends State<_AboutUpdateCheck> {
  bool _checking = false;
  String? _notice;

  Future<void> _check() async {
    if (!mounted || _checking) return;
    final route = ModalRoute.of(context);
    if (route is! PopupRoute || !route.isCurrent || !route.isActive) return;
    setState(() {
      _checking = true;
      _notice = null;
    });
    String? notice;
    try {
      notice = await widget.onCheck();
    } catch (error) {
      notice = UpdateChecker.checkFailureMessage(error);
    }
    if (!mounted) return;
    // A new version is announced by the existing footer. Close only this
    // dialog, and never a route opened while the request was in flight.
    if (notice == null && dismissSsrvpnDialog<void>(context)) return;
    setState(() {
      _checking = false;
      _notice = notice;
    });
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('ssrvpn-check-update-button'),
              onPressed: _checking ? null : _check,
              icon: const Icon(Icons.system_update_alt_rounded),
              label: Text(_checking ? '正在检查更新…' : '检查更新'),
            ),
          ),
          if (_notice != null) ...[
            const SizedBox(height: 8),
            Semantics(liveRegion: true, child: Text(_notice!)),
          ],
        ],
      );
}

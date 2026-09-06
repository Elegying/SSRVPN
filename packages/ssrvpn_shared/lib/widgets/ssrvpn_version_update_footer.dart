import 'package:flutter/material.dart';
import 'ssrvpn_home_text.dart';

class SsrvpnVersionUpdateFooter extends StatelessWidget {
  const SsrvpnVersionUpdateFooter({
    super.key,
    required this.version,
    required this.versionColor,
    required this.updateLabelColor,
    required this.updateActionColor,
    this.availableVersion,
    this.fitHomeText = false,
    this.onUpdateTap,
  });

  final bool fitHomeText;
  final String version;
  final Color versionColor;
  final Color updateLabelColor;
  final Color updateActionColor;
  final String? availableVersion;
  final VoidCallback? onUpdateTap;

  @override
  Widget build(BuildContext context) {
    final latestVersion = availableVersion;
    final updateAction = onUpdateTap;
    Widget label(String text, TextStyle style) => fitHomeText
        ? Expanded(
            child: SsrvpnHomeText(text,
                maxFontSize: 14, style: style, textAlign: TextAlign.center))
        : Text(text, style: style);
    final children = <Widget>[
      label(
        '版本号：$version',
        TextStyle(
          color: versionColor,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
          decoration: TextDecoration.none,
        ),
      ),
      if (latestVersion != null && updateAction != null) ...[
        label(
          '发现新版本',
          TextStyle(
            color: updateLabelColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        ),
        Tooltip(
          message: '打开 v$latestVersion 更新页',
          child: TextButton(
            key: const Key('ssrvpn-update-now-button'),
            onPressed: updateAction,
            style: TextButton.styleFrom(
              foregroundColor: updateActionColor,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(48, 48),
              textStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            child: fitHomeText
                ? const SizedBox(
                    width: 56, child: SsrvpnHomeText('立即更新', maxFontSize: 14))
                : const Text('立即更新'),
          ),
        ),
      ],
    ];
    return fitHomeText
        ? Row(mainAxisAlignment: MainAxisAlignment.center, children: children)
        : Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: children);
  }
}

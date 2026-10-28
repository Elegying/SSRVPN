import 'package:flutter/material.dart';
import 'ssrvpn_home_text.dart';
import 'ssrvpn_theme.dart';

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
    final palette = SsrvpnTheme.of(context);
    Widget label(String text, TextStyle style, {bool badge = false}) {
      Widget child = fitHomeText
          ? SsrvpnHomeText(text,
              maxFontSize: 14, style: style, textAlign: TextAlign.center)
          : Text(text, style: style);
      if (badge) {
        child = Align(
          widthFactor: 1,
          heightFactor: 1,
          child: DecoratedBox(
            key: const Key('ssrvpn-version-badge'),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              child: child,
            ),
          ),
        );
      }
      return fitHomeText ? Expanded(child: child) : child;
    }

    final children = <Widget>[
      label(
        '版本号：$version',
        TextStyle(
          color: MediaQuery.highContrastOf(context)
              ? palette.textPrimary
              : versionColor,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
          decoration: TextDecoration.none,
        ),
        badge: true,
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
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
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

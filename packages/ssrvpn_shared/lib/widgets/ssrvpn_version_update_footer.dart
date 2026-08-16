import 'package:flutter/material.dart';

class SsrvpnVersionUpdateFooter extends StatelessWidget {
  const SsrvpnVersionUpdateFooter({
    super.key,
    required this.version,
    required this.versionColor,
    required this.updateLabelColor,
    required this.updateActionColor,
    this.availableVersion,
    this.onUpdateTap,
  });

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
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        Text(
          '版本号：$version',
          style: TextStyle(
            color: versionColor,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
            decoration: TextDecoration.none,
          ),
        ),
        if (latestVersion != null && updateAction != null) ...[
          Text(
            '发现新版本',
            style: TextStyle(
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
              child: const Text('立即更新'),
            ),
          ),
        ],
      ],
    );
  }
}

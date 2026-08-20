import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import 'ssrvpn_app_surface.dart';

Future<void> showSsrvpnAboutDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: SsrvpnFrostedPanel(
        key: const Key('ssrvpn-about-glass'),
        borderRadius: 24,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: (MediaQuery.sizeOf(dialogContext).height - 56)
                .clamp(180.0, double.infinity),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.vpn_lock_rounded,
                            color: SsrvpnUiTokens.primary,
                          ),
                          SizedBox(width: 10),
                          Text(
                            'SSRVPN',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        '版本 ${AppConstants.appVersion}',
                        style: TextStyle(color: SsrvpnUiTokens.primary),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '项目地址',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      const SelectableText(
                        'https://github.com/Elegying/SSRVPN',
                        style: TextStyle(color: SsrvpnUiTokens.primaryBlue),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '免责声明',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '本软件仅供学习与研究使用，请遵守当地法律法规。\n'
                        '使用者应对自身行为承担全部责任。\n'
                        '开发者不对因使用本软件产生的任何后果负责。',
                        style: TextStyle(
                          color: SsrvpnUiTokens.textSecondary,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'By--两颗西柚',
                        style: TextStyle(color: SsrvpnUiTokens.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    backgroundColor:
                        SsrvpnUiTokens.primary.withValues(alpha: 0.14),
                  ),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

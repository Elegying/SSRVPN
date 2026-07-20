import 'package:flutter/material.dart';

import '../utils/log_redactor.dart';
import 'ssrvpn_app_surface.dart';

class SsrvpnSubscriptionErrorDialog extends StatelessWidget {
  const SsrvpnSubscriptionErrorDialog({
    super.key,
    required this.detail,
    this.title = '订阅刷新失败',
    this.guidance = '请确认设备已联网，并检查订阅地址或服务状态后重试',
  });

  final String detail;
  final String title;
  final String guidance;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight =
        (media.size.height - media.viewInsets.vertical - 48).clamp(1.0, 720.0);
    final safeDetail = LogRedactor.sanitizeForDisplay(detail);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: SsrvpnUiTokens.pageMaxWidth,
          maxHeight: maxHeight,
        ),
        child: SsrvpnSurfaceCard(
          padding: EdgeInsets.zero,
          radius: 16,
          color: SsrvpnUiTokens.backgroundRaised,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    key: const Key('ssrvpn-subscription-error-scroll'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: SsrvpnUiTokens.warning
                                .withValues(alpha: 20 / 255),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.cloud_off_rounded,
                            size: 28,
                            color: SsrvpnUiTokens.warning,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: SsrvpnUiTokens.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          guidance,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: SsrvpnUiTokens.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: SsrvpnUiTokens.error
                                .withValues(alpha: 10 / 255),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            safeDetail,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: SsrvpnUiTokens.error
                                  .withValues(alpha: 180 / 255),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    key: const Key('ssrvpn-subscription-error-confirm'),
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      foregroundColor: SsrvpnUiTokens.primary,
                      backgroundColor:
                          SsrvpnUiTokens.primary.withValues(alpha: 25 / 255),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      '知道了',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

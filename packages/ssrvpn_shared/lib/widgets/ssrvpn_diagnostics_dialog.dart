import 'package:flutter/material.dart';

import 'app_diagnostics_view.dart';
import 'ssrvpn_app_surface.dart';

Future<void> showSsrvpnDiagnosticsDialog(
  BuildContext context, {
  required RunAppDiagnostics runDiagnostics,
  required LoadAppDiagnosticHistory loadHistory,
  required RepairAppDiagnostic repair,
  ValueChanged<String>? onMessage,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: const Color(0xFF0E1018),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.88,
        ),
        child: SizedBox(
          width: 640,
          height: 560,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.bug_report,
                      size: 18,
                      color: SsrvpnUiTokens.warning,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '诊断与运行日志',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: SsrvpnUiTokens.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭诊断中心',
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: SsrvpnUiTokens.textSecondary,
                      ),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
                const Divider(color: SsrvpnUiTokens.border),
                Expanded(
                  child: AppDiagnosticsView(
                    runDiagnostics: runDiagnostics,
                    loadHistory: loadHistory,
                    repair: repair,
                    onMessage: onMessage,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

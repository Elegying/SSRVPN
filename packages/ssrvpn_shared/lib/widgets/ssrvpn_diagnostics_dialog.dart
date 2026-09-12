import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';
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
  return showSsrvpnGlassDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SsrvpnModalGlassPanel(
        key: const Key('ssrvpn-diagnostics-glass'),
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
                      Expanded(
                        child: Text(
                          '诊断与运行日志',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color:
                                Theme.of(dialogContext).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭诊断中心',
                        icon: Icon(
                          Icons.close,
                          size: 18,
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .onSurfaceVariant,
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
    ),
  );
}

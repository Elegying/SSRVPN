import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../services/clash_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';

void showAndroidDiagnosticsSheet(BuildContext context) {
  final clashService = context.read<ClashService>();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
      child: SsrvpnModalGlassPanel(
        key: const Key('ssrvpn-diagnostics-glass'),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.darkBorder)),
              ),
              child: Row(
                children: [
                  Icon(Icons.bug_report,
                      size: 18, color: AppTheme.warningColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '诊断与运行日志',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Responsive.sp(16),
                        fontWeight: FontWeight.w600,
                        color: Theme.of(ctx).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭诊断中心',
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: AppDiagnosticsView(
                  runDiagnostics: clashService.runDiagnostics,
                  loadHistory: clashService.loadDiagnosticHistory,
                  repair: clashService.repairDiagnosticIssue,
                  onMessage: (message) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                        content: Text(message),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

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
      child: Material(
        color: const Color(0xFF0E1018),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          side: BorderSide(color: AppTheme.darkBorder),
        ),
        clipBehavior: Clip.antiAlias,
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
                        color: AppTheme.darkTextPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭诊断中心',
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: AppTheme.darkTextSecondary,
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

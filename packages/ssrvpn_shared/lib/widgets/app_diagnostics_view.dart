import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_diagnostics.dart';

typedef RunAppDiagnostics = Future<AppDiagnosticReport> Function();
typedef RepairAppDiagnostic = Future<AppRepairResult> Function(
  AppRepairAction action,
);

/// Shared diagnostics UI for desktop dialogs and the Android bottom sheet.
class AppDiagnosticsView extends StatefulWidget {
  const AppDiagnosticsView({
    super.key,
    required this.runDiagnostics,
    required this.repair,
    this.onMessage,
  });

  final RunAppDiagnostics runDiagnostics;
  final RepairAppDiagnostic repair;
  final ValueChanged<String>? onMessage;

  @override
  State<AppDiagnosticsView> createState() => _AppDiagnosticsViewState();
}

class _AppDiagnosticsViewState extends State<AppDiagnosticsView> {
  AppDiagnosticReport? _report;
  bool _loading = true;
  bool _failed = false;
  AppRepairAction? _repairing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final report = await widget.runDiagnostics();
      if (!mounted) return;
      setState(() => _report = report);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _report = null;
        _failed = true;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _repair(AppRepairAction action) async {
    if (_repairing != null) return;
    setState(() => _repairing = action);
    AppRepairResult result;
    try {
      result = await widget.repair(action);
    } catch (_) {
      result = const AppRepairResult(
        success: false,
        message: '修复未能完成，未修改其他系统网络设置。',
      );
    }
    if (!mounted) return;
    widget.onMessage?.call(result.message);
    setState(() => _repairing = null);
    await _load();
  }

  Future<void> _copyReport() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report.toText()));
    widget.onMessage?.call('诊断报告已复制（敏感内容已脱敏）');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading && _report == null) {
      return Semantics(
        label: '正在运行诊断',
        liveRegion: true,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_failed) {
      return Semantics(
        liveRegion: true,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(height: 8),
              const Text('诊断未能完成'),
              const SizedBox(height: 4),
              Text(
                '没有修改任何系统状态，请稍后重试。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final report = _report!;
    final failureCount = report.checks
        .where((check) => check.status == AppDiagnosticStatus.failed)
        .length;
    final warningCount = report.checks
        .where((check) => check.status == AppDiagnosticStatus.warning)
        .length;
    final summary = failureCount > 0
        ? '发现 $failureCount 项需要处理的问题'
        : warningCount > 0
            ? '检查完成，发现 $warningCount 项提醒'
            : '检查完成，未发现异常';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  summary,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Semantics(
                button: true,
                label: '复制脱敏诊断报告',
                child: ExcludeSemantics(
                  child: IconButton(
                    tooltip: '复制脱敏诊断报告',
                    onPressed: _copyReport,
                    icon: const Icon(Icons.copy, size: 19),
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: '重新运行诊断',
                child: ExcludeSemantics(
                  child: IconButton(
                    tooltip: '重新运行诊断',
                    onPressed: _loading ? null : _load,
                    icon: _loading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 20),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              for (final check in report.checks)
                _DiagnosticCheckTile(
                  check: check,
                  repairing: _repairing == check.repairAction,
                  onRepair: check.repairAction == null
                      ? null
                      : () => _repair(check.repairAction!),
                ),
              if (report.recentLogs.trim().isNotEmpty)
                ExpansionTile(
                  leading: const Icon(Icons.article_outlined, size: 20),
                  title: const Text('最近日志（已脱敏）'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        report.recentLogs,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DiagnosticCheckTile extends StatelessWidget {
  const _DiagnosticCheckTile({
    required this.check,
    required this.repairing,
    required this.onRepair,
  });

  final AppDiagnosticCheck check;
  final bool repairing;
  final VoidCallback? onRepair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, statusLabel) = switch (check.status) {
      AppDiagnosticStatus.passed => (
          Icons.check_circle_outline,
          Colors.green,
          '通过'
        ),
      AppDiagnosticStatus.warning => (
          Icons.warning_amber_rounded,
          Colors.orange,
          '提醒'
        ),
      AppDiagnosticStatus.failed => (
          Icons.error_outline,
          theme.colorScheme.error,
          '失败'
        ),
      AppDiagnosticStatus.skipped => (
          Icons.remove_circle_outline,
          theme.colorScheme.outline,
          '已跳过'
        ),
    };
    final code = check.errorCode?.wireName;

    return Semantics(
      label: '${check.title}，$statusLabel，${check.summary}',
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(icon, color: color, size: 21)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(check.title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(check.summary, style: theme.textTheme.bodySmall),
                    if (code != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        code,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                          color: color,
                        ),
                      ),
                    ],
                    if (onRepair != null) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: repairing ? null : onRepair,
                        icon: repairing
                            ? const SizedBox.square(
                                dimension: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.build_outlined, size: 16),
                        label: const Text('修复系统代理'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

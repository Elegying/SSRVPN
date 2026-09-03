import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_diagnostics.dart';
import '../services/app_diagnostic_history_store.dart';
import '../utils/log_redactor.dart';

typedef RunAppDiagnostics = Future<AppDiagnosticReport> Function();
typedef RepairAppDiagnostic = Future<AppRepairResult> Function(
  AppRepairAction action,
);
typedef LoadAppDiagnosticHistory = Future<List<AppDiagnosticHistoryEntry>>
    Function();

@visibleForTesting
bool diagnosticClipboardMatchesReport(
    String? clipboardText, String reportText) {
  if (clipboardText == null) return false;
  String normalizeNewlines(String value) =>
      value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return normalizeNewlines(clipboardText) == normalizeNewlines(reportText);
}

/// Shared diagnostics UI for desktop dialogs and the Android bottom sheet.
class AppDiagnosticsView extends StatefulWidget {
  const AppDiagnosticsView({
    super.key,
    required this.runDiagnostics,
    required this.loadHistory,
    required this.repair,
    this.onMessage,
  });

  final RunAppDiagnostics runDiagnostics;
  final LoadAppDiagnosticHistory loadHistory;
  final RepairAppDiagnostic repair;
  final ValueChanged<String>? onMessage;

  @override
  State<AppDiagnosticsView> createState() => _AppDiagnosticsViewState();
}

class _AppDiagnosticsViewState extends State<AppDiagnosticsView> {
  AppDiagnosticReport? _report;
  List<AppDiagnosticHistoryEntry> _history = const [];
  bool _loading = true;
  bool _failed = false;
  AppRepairAction? _repairing;
  String? _copyStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _copyStatus = null;
    });
    try {
      final report = await widget.runDiagnostics();
      List<AppDiagnosticHistoryEntry> history;
      try {
        history = await widget.loadHistory();
      } catch (_) {
        history = const [];
      }
      if (!mounted) return;
      setState(() {
        _report = report;
        _history = history;
      });
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
    const success = '诊断报告已复制（敏感内容已脱敏）';
    const failure = '复制失败，请重试';
    try {
      final reportText = report.toText();
      await Clipboard.setData(ClipboardData(text: reportText));
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (!diagnosticClipboardMatchesReport(clipboard?.text, reportText)) {
        throw StateError('clipboard write verification failed');
      }
      if (!mounted) return;
      setState(() => _copyStatus = success);
      widget.onMessage?.call(success);
    } catch (_) {
      if (!mounted) return;
      setState(() => _copyStatus = failure);
      widget.onMessage?.call(failure);
    }
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
    final readableLogs = report.readableLogs;
    final summaryText = Text(
      report.userConclusion,
      style: theme.textTheme.titleSmall,
    );
    final summaryActions = <Widget>[
      Semantics(
        button: true,
        label: '复制脱敏诊断报告',
        onTap: _copyReport,
        child: ExcludeSemantics(
          child: TextButton.icon(
            onPressed: _copyReport,
            icon: const Icon(Icons.copy, size: 18),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 56),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('复制报告'),
              ),
            ),
          ),
        ),
      ),
      Semantics(
        button: true,
        label: '重新运行诊断',
        child: ExcludeSemantics(
          child: TextButton.icon(
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 18),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 56),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('重新检查'),
              ),
            ),
          ),
        ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              summaryText,
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  children: summaryActions,
                ),
              ),
            ],
          ),
        ),
        if (_copyStatus != null) ...[
          const SizedBox(height: 6),
          Semantics(
            container: true,
            liveRegion: true,
            label: _copyStatus,
            excludeSemantics: true,
            child: Text(
              _copyStatus!,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.end,
            ),
          ),
        ],
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
              if (readableLogs.isNotEmpty)
                ExpansionTile(
                  leading: const Icon(Icons.article_outlined, size: 20),
                  title: Text('最近运行记录（${readableLogs.length}）'),
                  subtitle: const Text('已按本地时间整理，并隐藏内部标识'),
                  initiallyExpanded:
                      readableLogs.any((entry) => entry.requiresAttention),
                  children: [
                    for (final entry in readableLogs)
                      _ReadableLogTile(entry: entry),
                  ],
                ),
              if (report.recentLogs.trim().isNotEmpty)
                ExpansionTile(
                  leading: const Icon(Icons.code_rounded, size: 20),
                  title: const Text('技术明细（已脱敏）'),
                  subtitle: const Text('仅在需要深入排障时查看'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        LogRedactor.sanitizeForDisplay(report.recentLogs),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              if (_history.isNotEmpty)
                ExpansionTile(
                  leading: const Icon(Icons.history, size: 20),
                  title: Text('本地诊断历史（${_history.length}）'),
                  subtitle: const Text('仅保留最近 20 份已脱敏报告'),
                  children: [
                    for (final entry in _history)
                      ExpansionTile(
                        title: Text(
                          entry.generatedAt.toLocal().toIso8601String(),
                          style: theme.textTheme.bodyMedium,
                        ),
                        subtitle: Text(
                          '失败 ${entry.failureCount} · 提醒 ${entry.warningCount}',
                        ),
                        childrenPadding:
                            const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(
                              entry.reportText,
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
            ],
          ),
        ),
      ],
    );
  }
}

class _ReadableLogTile extends StatelessWidget {
  const _ReadableLogTile({required this.entry});

  final AppDiagnosticLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (entry.level) {
      AppDiagnosticLogLevel.information => (
          Icons.info_outline_rounded,
          theme.colorScheme.primary,
        ),
      AppDiagnosticLogLevel.warning => (
          Icons.warning_amber_rounded,
          Colors.orange,
        ),
      AppDiagnosticLogLevel.error => (
          Icons.error_outline_rounded,
          theme.colorScheme.error,
        ),
    };
    return Semantics(
      label:
          '${entry.timeLabel}，${entry.levelLabel}，${entry.category}，${entry.message}',
      child: Card(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(icon, color: color, size: 20)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          entry.levelLabel,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(entry.category,
                            style: theme.textTheme.labelMedium),
                        Text(
                          entry.timeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(entry.message, style: theme.textTheme.bodySmall),
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/crash_reporter.dart';

enum _CrashReportAction { later, delete, send }

class CrashReportPrompt extends StatefulWidget {
  const CrashReportPrompt({
    super.key,
    required this.child,
    this.supportHint = '请粘贴给开发者。',
  });

  final Widget child;
  final String supportHint;

  @override
  State<CrashReportPrompt> createState() => _CrashReportPromptState();
}

class _CrashReportPromptState extends State<CrashReportPrompt> {
  bool _checked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checked) return;
    _checked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showIfNeeded());
    });
  }

  Future<void> _showIfNeeded() async {
    final reports = await CrashReporter.pendingReports();
    if (!mounted || reports.isEmpty) return;

    final action = await showDialog<_CrashReportAction>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('上次崩溃了'),
        content: Text(
          '检测到 ${reports.length} 份崩溃报告。是否发送报告？报告会先复制到剪贴板，${widget.supportHint}',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _CrashReportAction.later),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _CrashReportAction.delete),
            child: const Text('删除'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _CrashReportAction.send),
            child: const Text('发送报告'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    switch (action) {
      case _CrashReportAction.send:
        final content = await CrashReporter.readReports(reports);
        await Clipboard.setData(ClipboardData(text: content));
        await CrashReporter.deleteReports(reports);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('崩溃报告已复制到剪贴板')),
        );
        break;
      case _CrashReportAction.delete:
        await CrashReporter.deleteReports(reports);
        break;
      case _CrashReportAction.later:
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

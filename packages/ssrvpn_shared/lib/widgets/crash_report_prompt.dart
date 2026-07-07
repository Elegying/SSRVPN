import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/crash_reporter.dart';

enum _CrashReportAction { later, delete, send }

class CrashReportPrompt extends StatefulWidget {
  const CrashReportPrompt({
    super.key,
    required this.child,
    this.supportHint = '请到 GitHub Issues 新建崩溃报告并粘贴文本日志，不要公开 .dmp 或订阅链接。',
    this.supportUrl =
        'https://github.com/Elegying/SSRVPN/issues/new?template=bug_report.yml',
  });

  final Widget child;
  final String supportHint;
  final String? supportUrl;

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
          '检测到 ${reports.length} 份崩溃报告。是否复制文本报告？复制前请确认内容不包含订阅凭据；不要公开发送 .dmp 文件。${widget.supportHint}',
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
        final supportUrl = widget.supportUrl;
        final clipboardText = supportUrl == null || supportUrl.isEmpty
            ? content
            : '提交入口: $supportUrl\n\n$content';
        await Clipboard.setData(ClipboardData(text: clipboardText));
        await CrashReporter.deleteReports(reports);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('崩溃报告已复制到剪贴板，请打开提交入口')),
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

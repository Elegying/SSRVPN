import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/crash_reporter.dart';
import '../utils/app_logger.dart';
import '../utils/app_modal_coordinator.dart';

enum _CrashReportAction { later, delete, copy }

class CrashReportPrompt extends StatefulWidget {
  const CrashReportPrompt({
    super.key,
    required this.child,
    this.supportHint = '请到 GitHub Issues 新建崩溃报告并粘贴文本日志，不要公开 .dmp 或订阅链接。',
    this.supportUrl =
        'https://github.com/Elegying/SSRVPN/issues/new?template=bug_report.yml',
    this.pendingReportsLoader,
    this.reportReader,
    this.reportDeleter,
    this.clipboardWriter,
  });

  final Widget child;
  final String supportHint;
  final String? supportUrl;
  final Future<List<File>> Function()? pendingReportsLoader;
  final Future<String> Function(List<File>)? reportReader;
  final Future<void> Function(List<File>)? reportDeleter;
  final Future<void> Function(String)? clipboardWriter;

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
      if (!mounted) return;
      unawaited(_showIfNeeded());
    });
  }

  Future<void> _showIfNeeded() async {
    try {
      final reports =
          await (widget.pendingReportsLoader ?? CrashReporter.pendingReports)();
      if (!mounted || reports.isEmpty) return;

      final action = await AppModalCoordinator.run<_CrashReportAction?>(() {
        if (!mounted) return Future.value();
        return showDialog<_CrashReportAction>(
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
                    Navigator.pop(dialogContext, _CrashReportAction.copy),
                child: const Text('复制报告'),
              ),
            ],
          ),
        );
      });

      if (!mounted) return;
      switch (action) {
        case _CrashReportAction.copy:
          final content =
              await (widget.reportReader ?? CrashReporter.readReports)(
            reports,
          );
          final supportUrl = widget.supportUrl;
          final clipboardText = supportUrl == null || supportUrl.isEmpty
              ? content
              : '提交入口: $supportUrl\n\n$content';
          final clipboardWriter = widget.clipboardWriter;
          if (clipboardWriter == null) {
            await Clipboard.setData(ClipboardData(text: clipboardText));
          } else {
            await clipboardWriter(clipboardText);
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('报告已复制且仍保留在本机；确认提交成功后可返回删除'),
            ),
          );
          break;
        case _CrashReportAction.delete:
          await (widget.reportDeleter ?? CrashReporter.deleteReports)(reports);
          break;
        case _CrashReportAction.later:
        case null:
          break;
      }
    } catch (error) {
      AppLogger.warning('CrashReport', '崩溃报告操作失败: $error');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('崩溃报告操作失败，未确认报告已删除，请稍后重试'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

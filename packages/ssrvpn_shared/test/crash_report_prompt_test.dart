import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/crash_report_prompt.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? copiedText;
  var deleteCalls = 0;

  setUp(() {
    copiedText = null;
    deleteCalls = 0;
  });

  testWidgets('copying a crash report preserves it until explicit deletion',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CrashReportPrompt(
          pendingReportsLoader: () async => [File('crash_fake.txt')],
          reportReader: (_) async => 'SSRVPN Crash Report',
          reportDeleter: (_) async => deleteCalls++,
          clipboardWriter: (text) async => copiedText = text,
          child: const Scaffold(body: Text('app')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('复制报告'), findsOneWidget);
    await tester.tap(find.text('复制报告'));
    await tester.pumpAndSettle();

    expect(copiedText, contains('SSRVPN Crash Report'));
    expect(deleteCalls, 0);
    expect(
      find.text('报告已复制且仍保留在本机；确认提交成功后可返回删除'),
      findsOneWidget,
    );
  });

  testWidgets('loader failure stays contained and reports a retryable error',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CrashReportPrompt(
          pendingReportsLoader: () async => throw StateError('loader failed'),
          child: const Scaffold(body: Text('app')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('崩溃报告操作失败，未确认报告已删除，请稍后重试'), findsOneWidget);
  });

  testWidgets('reader failure preserves the report and stays contained',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CrashReportPrompt(
          pendingReportsLoader: () async => [File('crash_fake.txt')],
          reportReader: (_) async => throw StateError('read failed'),
          reportDeleter: (_) async => deleteCalls++,
          clipboardWriter: (text) async => copiedText = text,
          child: const Scaffold(body: Text('app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制报告'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(copiedText, isNull);
    expect(deleteCalls, 0);
    expect(find.text('崩溃报告操作失败，未确认报告已删除，请稍后重试'), findsOneWidget);
  });

  testWidgets('clipboard failure preserves the report and stays contained',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CrashReportPrompt(
          pendingReportsLoader: () async => [File('crash_fake.txt')],
          reportReader: (_) async => 'SSRVPN Crash Report',
          reportDeleter: (_) async => deleteCalls++,
          clipboardWriter: (_) async => throw StateError('clipboard failed'),
          child: const Scaffold(body: Text('app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制报告'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(deleteCalls, 0);
    expect(find.text('崩溃报告操作失败，未确认报告已删除，请稍后重试'), findsOneWidget);
  });

  testWidgets('delete failure remains retryable and stays contained',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CrashReportPrompt(
          pendingReportsLoader: () async => [File('crash_fake.txt')],
          reportReader: (_) async => 'SSRVPN Crash Report',
          reportDeleter: (_) async => throw StateError('delete failed'),
          clipboardWriter: (text) async => copiedText = text,
          child: const Scaffold(body: Text('app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('崩溃报告操作失败，未确认报告已删除，请稍后重试'), findsOneWidget);
  });
}

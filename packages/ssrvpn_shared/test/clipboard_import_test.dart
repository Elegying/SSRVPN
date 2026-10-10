import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_clipboard_import.dart';

void main() {
  testWidgets('late clipboard result logs without a toast after returning home',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'trojan://synthetic@node.example.com:443#Test'}
            : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    var onHome = false;
    final logs = <String>[];
    final pending = Completer<String>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnClipboardImport(
                alreadyImported: (_) => false,
                shouldShowNotice: () => !onHome,
                onDiagnostic: logs.add,
                onImport: (_) => pending.future,
                child: const Text('主页')))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    onHome = true;
    pending.complete('导入失败，请重试');
    await tester.pumpAndSettle();
    expect(logs, ['导入失败，请重试']);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'background dismissal does not permanently suppress an unanswered node',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'trojan://test-password@node.example.com:443#Test'}
            : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    var imports = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnClipboardImport(
                alreadyImported: (_) => false,
                onImport: (_) async {
                  imports++;
                  return '节点已导入';
                },
                child: const Text('Home')))));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsOneWidget);
    expect(imports, 0);
    await tester.tap(find.text('暂不导入'));
    // A lifecycle change during the outgoing animation must preserve refusal.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'foreground-only clipboard checks, confirmation and repeat suppression',
      (tester) async {
    String text = 'ordinary text';
    var reads = 0, imports = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        return {'text': text};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnClipboardImport(
                alreadyImported: (_) => false,
                onImport: (_) async {
                  imports++;
                  return '节点已导入';
                },
                child: const Text('Home')))));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsNothing);
    text = 'trojan://test-password@node.example.com:443#Test';
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsOneWidget);
    expect(imports, 0);
    expect(find.textContaining('test-password'), findsNothing);
    await tester.tap(find.text('暂不导入'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final before = reads;
    text = 'trojan://test-password@node.example.com:443#Another';
    await tester.pump(const Duration(seconds: 6));
    expect(reads, before);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板节点'), findsOneWidget);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(imports, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('OS denial leaves the app usable and cancels polling on disposal',
      (tester) async {
    var reads = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        throw PlatformException(code: 'denied');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnClipboardImport(
                alreadyImported: (_) => false,
                onImport: (_) async => 'Imported',
                child: const Text('Home')))));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final before = reads;
    await tester.pump(const Duration(seconds: 6));
    expect(reads, before);
  });
}

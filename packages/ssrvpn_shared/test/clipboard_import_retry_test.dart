import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_clipboard_import.dart';

void main() {
  for (final throws in [false, true]) {
    testWidgets(
        'explicit retry stays quiet, confirms again and stops after commit: throws=$throws',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      const code = 'trojan://test-password@node.example.com:443#Retry';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async =>
              call.method == 'Clipboard.getData' ? {'text': code} : null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      var imports = 0, committed = false;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SsrvpnClipboardImport(
        alreadyImported: (_) => committed,
        onImport: (_) async {
          imports++;
          if (imports == 1) {
            if (throws) throw StateError('private raw details');
            return '导入失败';
          }
          committed = true;
          return '节点已导入';
        },
        child: const Text('Home'),
      ))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(imports, 1);
      expect(find.text('发现剪贴板节点'), findsNothing);
      expect(find.textContaining('private raw details'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('发现剪贴板节点'), findsOneWidget);
      expect(imports, 1);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(imports, 2);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('发现剪贴板节点'), findsNothing);
      expect(find.text('重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets(
      'failed clipboard import can be retried after copying the same node',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    String text = 'trojan://test-password@node.example.com:443#Retry';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': text} : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    var imports = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnClipboardImport(
      alreadyImported: (_) => false,
      onImport: (_) async {
        imports++;
        return '导入失败，请检查节点代码后重试';
      },
      child: const Text('Home'),
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(find.text('导入失败，请检查节点代码后重试'), findsOneWidget);
    text = 'ordinary text';
    await tester.pump(const Duration(seconds: 3));
    text = 'trojan://test-password@node.example.com:443#Retry';
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    final prompts = find.text('发现剪贴板节点').evaluate().length;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(prompts, 1,
        reason:
            'No import committed, and the user copied the node again to retry');
  });
}

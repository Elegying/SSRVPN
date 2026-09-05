import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_macos/screens/node_edit_screen.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';
import 'package:ssrvpn_macos/services/subscription_service.dart';
import 'package:ssrvpn_macos/theme/app_theme.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final failure in ['duplicate', 'preference', 'node', 'rollback']) {
    testWidgets(
        'node edit reports $failure failure and restores its save control',
        (tester) async {
      late Directory directory;
      late _EditorFaultSubscription subscription;
      late SettingsService settings;
      var writes = 0;
      final targetName = failure == 'duplicate' ? 'Second' : 'Edited';
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('ssrvpn-node-edit-');
        subscription = _EditorFaultSubscription();
        await subscription.init(directory.path);
        await subscription.setRawYaml('proxies:\n'
            '  - {name: Original, type: socks5, server: original.invalid, port: 443}\n'
            '  - {name: Second, type: socks5, server: second.invalid, port: 443}\n');
        settings = await SettingsService.createForTesting(
            settings: AppSettings(lastSelectedNodeName: 'Original'),
            dataDir: directory.path,
            settingsPath: '${directory.path}/settings.json',
            readApiSecret: () async => '',
            writeApiSecret: (_) async {},
            writeSettings: (_) async {
              writes++;
              if ((failure == 'preference' && writes == 1) ||
                  (failure == 'rollback' && writes == 2)) {
                throw const FileSystemException(
                    'synthetic settings write failure');
              }
            });
        subscription.failNextCache = failure != 'duplicate';
      });
      addTearDown(() async {
        subscription.dispose();
        settings.dispose();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<SubscriptionService>.value(
                value: subscription),
            ChangeNotifierProvider<SettingsService>.value(value: settings),
          ],
          child: MaterialApp(
              theme: AppTheme.light,
              home: NodeEditScreen(node: subscription.allNodes.first))));
      await tester.enterText(find.byType(TextFormField).first, targetName);
      final submit = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed! as Future<void> Function();
      await tester.runAsync(submit);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(subscription.allNodes.first.name, 'Original');
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
              .onPressed,
          isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      if (failure == 'rollback') {
        expect(find.textContaining('首选节点恢复失败'), findsOneWidget);
      } else {
        expect(settings.settings.lastSelectedNodeName, 'Original');
      }
      expect(writes,
          switch (failure) { 'duplicate' => 0, 'preference' => 1, _ => 2 });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('renders current node values', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: NodeEditScreen(node: _node()),
      ),
    );

    expect(find.text('编辑节点'), findsOneWidget);
    expect(find.text('测试节点'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('8388'), findsOneWidget);
    expect(find.text('SS 参数'), findsOneWidget);
  });

  testWidgets('validates port range before saving', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: NodeEditScreen(node: _node()),
      ),
    );

    await tester.enterText(find.byType(TextFormField).at(2), '70000');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('端口必须在 1-65535 之间'), findsOneWidget);
  });

  testWidgets('advanced JSON editor uses an explicit macOS monospace chain',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: NodeEditScreen(node: _node()),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('其他参数（JSON）'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final editorStyles = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .map((editor) => editor.style);
    expect(editorStyles.map((style) => style.fontFamily), contains('Menlo'));
    expect(
      editorStyles.map((style) => style.fontFamilyFallback),
      contains(const <String>['Consolas']),
    );
  });
}

ProxyNode _node() {
  return ProxyNode(
    name: '测试节点',
    type: 'ss',
    server: 'example.com',
    port: 8388,
    extra: const {
      'name': '测试节点',
      'type': 'ss',
      'server': 'example.com',
      'port': 8388,
      'cipher': 'aes-128-gcm',
      'password': 'secret',
    },
  );
}

class _EditorFaultSubscription extends SubscriptionServiceBase
    implements SubscriptionService {
  bool failNextCache = false;

  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      throw StateError('unexpected fetch');
  @override
  Future<void> cacheYaml(String yaml) async {
    if (failNextCache) {
      failNextCache = false;
      throw const FileSystemException('synthetic node save failure');
    }
    await super.cacheYaml(yaml);
  }
}

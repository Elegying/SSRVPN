import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_android/screens/node_edit_screen.dart';
import 'package:ssrvpn_android/services/settings_service.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
import 'package:ssrvpn_android/utils/responsive.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  ProxyNode node({
    String name = '测试节点',
    String type = 'ss',
    String server = 'example.com',
    int port = 8388,
    Map<String, dynamic> extra = const {},
  }) {
    return ProxyNode(
      name: name,
      type: type,
      server: server,
      port: port,
      extra: {
        'name': name,
        'type': type,
        'server': server,
        'port': port,
        ...extra,
      },
    );
  }

  Widget host(Widget child) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      home: Builder(
        builder: (context) {
          Responsive.init(context);
          return child;
        },
      ),
    );
  }

  testWidgets('saving a name with controls preserves the chosen endpoint',
      (tester) async {
    late Directory directory;
    late _EditorFaultSubscription subscription;
    late SettingsService settings;
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('ssrvpn-canonical-edit-');
      subscription = _EditorFaultSubscription();
      await subscription.init(directory.path);
      await subscription.setRawYaml('proxies:\n'
          '  - {name: Decoy, type: socks5, server: decoy.invalid, port: 443}\n'
          '  - {name: Original, type: socks5, server: chosen.invalid, port: 443}\n');
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsService.createForTesting(
        configPath: '${directory.path}/settings.json',
        readApiSecret: () async => 'synthetic-secret',
        writeApiSecret: (_) async {},
      );
      await settings.setLastSelectedNodeName('Original');
    });
    addTearDown(() async {
      subscription.dispose();
      settings.dispose();
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<SubscriptionService>.value(value: subscription),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
      ],
      child: host(Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) =>
                              NodeEditScreen(node: subscription.allNodes.last),
                        )),
                    child: const Text('Open editor')),
              ))),
    ));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Edited\tNode');
    final save = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
        .onPressed! as Future<void> Function();
    await tester.runAsync(save);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Open editor'), findsOneWidget);
    expect(subscription.allNodes.last.name, 'EditedNode');
    expect(settings.settings.lastSelectedNodeName, 'EditedNode');
    late Map<String, dynamic> persisted;
    await tester.runAsync(() async {
      persisted = jsonDecode(
              await File('${directory.path}/settings.json').readAsString())
          as Map<String, dynamic>;
    });
    expect(persisted['lastSelectedNodeName'], 'EditedNode');
    expect(
        HomeNodeController.resolveDefaultNodeFrom(
                subscription.allNodes, settings.settings.lastSelectedNodeName)!
            .server,
        'chosen.invalid');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final failure in ['duplicate', 'preference', 'node', 'rollback']) {
    testWidgets(
        'node edit reports $failure failure and restores its save control',
        (tester) async {
      late Directory directory;
      late _EditorFaultSubscription subscription;
      late SettingsService settings;
      var writes = 0;
      Future<void> blockSettingsFile() async {
        final file = File('${directory.path}/settings.json');
        if (await file.exists()) await file.delete();
        await Directory(file.path).create();
      }

      final targetName = failure == 'duplicate' ? 'Second' : 'Edited';
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('ssrvpn-node-edit-');
        subscription = _EditorFaultSubscription();
        await subscription.init(directory.path);
        await subscription.setRawYaml('proxies:\n'
            '  - {name: Original, type: socks5, server: original.invalid, port: 443}\n'
            '  - {name: Second, type: socks5, server: second.invalid, port: 443}\n');
        settings = await SettingsService.createForTesting(
            configPath: '${directory.path}/settings.json',
            readApiSecret: () async => 'synthetic-secret',
            writeApiSecret: (_) async {});
        await settings.setLastSelectedNodeName('Original');
        subscription.beforeCacheFailure = () async {
          if (failure == 'rollback') await blockSettingsFile();
        };
        settings.addListener(() => writes++);
        if (failure == 'preference') await blockSettingsFile();
        subscription.failNextCache = failure != 'duplicate';
      });
      addTearDown(() async {
        subscription.dispose();
        settings.dispose();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider<SubscriptionService>.value(value: subscription),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
      ], child: host(NodeEditScreen(node: subscription.allNodes.first))));
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
      expect(
          writes,
          switch (failure) {
            'duplicate' || 'preference' || 'rollback' => 0,
            _ => 1
          });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
  testWidgets('editor renders protocol-specific fields and preserved extras',
      (tester) async {
    final ssrNode = node(
      type: 'ssr',
      extra: const {
        'password': 'secret',
        'cipher': 'aes-256-cfb',
        'protocol': 'auth_sha1_v4',
        'protocol-param': 'param',
        'obfs': 'tls1.2_ticket_auth',
        'obfs-param': 'cdn.example.com',
        'plugin': 'obfs-local',
      },
    );

    await tester.pumpWidget(host(NodeEditScreen(node: ssrNode)));

    expect(find.text('编辑节点'), findsOneWidget);
    expect(find.text('修改仅保存在本地，刷新订阅后会被订阅内容覆盖。'), findsOneWidget);
    expect(find.text('测试节点'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('8388'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('加密方式'), findsOneWidget);
    expect(find.text('协议'), findsOneWidget);
    expect(find.text('协议参数'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('混淆'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('混淆'), findsOneWidget);
    expect(find.text('混淆参数'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('其他参数（JSON）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('"plugin": "obfs-local"'), findsOneWidget);
    expect(find.text('TLS、插件、WebSocket 等未列出的参数可在这里修改'), findsOneWidget);
  });

  testWidgets('changing protocol updates the editable field surface',
      (tester) async {
    await tester.pumpWidget(host(NodeEditScreen(node: node())));

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('vless').last);
    await tester.pumpAndSettle();

    expect(find.text('UUID'), findsOneWidget);
    expect(find.text('传输协议'), findsOneWidget);
    expect(find.text('Flow'), findsOneWidget);
    expect(find.text('SNI'), findsOneWidget);
    expect(find.text('加密方式'), findsNothing);
  });

  testWidgets('required fields and port are validated before persistence',
      (tester) async {
    await tester.pumpWidget(host(NodeEditScreen(node: node())));
    final fields = find.byType(TextFormField);

    await tester.enterText(fields.at(0), '');
    await tester.enterText(fields.at(1), '');
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pump();
    expect(find.text('请输入备注名'), findsOneWidget);
    expect(find.text('请输入服务器地址'), findsOneWidget);

    await tester.enterText(fields.at(0), '有效名称');
    await tester.enterText(fields.at(1), 'valid.example.com');
    await tester.enterText(fields.at(2), '70000');
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pump();
    expect(find.text('端口必须是 1-65535 之间的数字'), findsOneWidget);
  });

  testWidgets('other parameters must be a JSON object before persistence',
      (tester) async {
    await tester.pumpWidget(host(NodeEditScreen(node: node())));

    await tester.scrollUntilVisible(
      find.text('其他参数（JSON）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final extrasField = find.ancestor(
      of: find.text('其他参数（JSON）'),
      matching: find.byType(TextFormField),
    );
    expect(extrasField, findsOneWidget);
    await tester.enterText(extrasField, '["not", "an", "object"]');
    final field = tester.widget<TextFormField>(extrasField);
    expect(field.controller!.text, '["not", "an", "object"]');
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pump();
    expect(find.text('其他参数必须是有效的 JSON 对象'), findsOneWidget);
  });
}

class _EditorFaultSubscription extends SubscriptionServiceBase
    implements SubscriptionService {
  bool failNextCache = false;
  Future<void> Function()? beforeCacheFailure;
  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      throw StateError('unexpected fetch');
  @override
  Future<void> cacheYaml(String yaml) async {
    if (failNextCache) {
      failNextCache = false;
      await beforeCacheFailure?.call();
      throw const FileSystemException('synthetic node save failure');
    }
    await super.cacheYaml(yaml);
  }
}

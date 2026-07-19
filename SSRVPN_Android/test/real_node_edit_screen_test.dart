import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/screens/node_edit_screen.dart';
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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_client/screens/node_edit_screen.dart';
import 'package:ssrvpn_client/theme/app_theme.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
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

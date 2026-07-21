import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_macos/screens/subscription_screen.dart';
import 'package:ssrvpn_macos/services/clash_service.dart';
import 'package:ssrvpn_macos/services/subscription_service.dart';
import 'package:ssrvpn_macos/theme/app_theme.dart';

const _singleNodeUrl =
    'ss://aes-256-gcm:pass123@127.0.0.1:8388#Keyboard%20Node';
const _nodeYaml = '''
proxies:
  - name: Keyboard Node
    type: ss
    server: 127.0.0.1
    port: 8388
    cipher: aes-256-gcm
    password: pass123
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SubscriptionService.resetInstanceForTesting);

  testWidgets('subscription page has no about action', (tester) async {
    final fixture =
        (await tester.runAsync(() => _SubscriptionFixture.create()))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();

    expect(find.text('订阅管理'), findsOneWidget);
    expect(find.text('添加订阅'), findsOneWidget);
    expect(find.text('关于'), findsNothing);
    expect(find.bySemanticsLabel('打开关于 SSRVPN'), findsNothing);
  });

  testWidgets('ordinary deletion confirms success to the user', (tester) async {
    final fixture = (await tester.runAsync(
      () => _SubscriptionFixture.create(withSubscription: true),
    ))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();

    await tester.tap(find.byTooltip('删除订阅'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.text('订阅已删除'));

    expect(fixture.subscription.subscriptions, isEmpty);
    expect(find.text('订阅已删除'), findsOneWidget);
  });
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

class _SubscriptionFixture {
  const _SubscriptionFixture({
    required this.directory,
    required this.subscription,
    required this.clash,
  });

  final Directory directory;
  final SubscriptionService subscription;
  final ClashService clash;

  static Future<_SubscriptionFixture> create({
    bool withSubscription = false,
  }) async {
    SubscriptionService.resetInstanceForTesting();
    final directory = Directory.systemTemp.createTempSync('ssrvpn_sub_ui_');
    final subscription = await SubscriptionService.getInstance(directory.path);
    if (withSubscription) {
      await subscription.addSubscription('测试订阅', _singleNodeUrl);
      await subscription.setRawYaml(_nodeYaml);
    }
    return _SubscriptionFixture(
      directory: directory,
      subscription: subscription,
      clash: _IdleClashService(),
    );
  }

  Widget build() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SubscriptionService>.value(value: subscription),
        Provider<ClashService>.value(value: clash),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: const SubscriptionScreen(),
      ),
    );
  }

  void dispose() {
    subscription.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

class _IdleClashService extends ClashService {
  @override
  bool get isRunning => false;
}

import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('about action exposes semantics and opens from the keyboard',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture =
        (await tester.runAsync(() => _SubscriptionFixture.create()))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();

    final aboutAction = find.bySemanticsLabel('打开关于 SSRVPN');
    expect(aboutAction, findsOneWidget);
    expect(tester.getSemantics(aboutAction).flagsCollection.isButton, isTrue);
    await _focusSemanticAction(tester, aboutAction);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('免责声明'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    semantics.dispose();
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
    final deleteButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(deleteButton.onPressed, isNull);
    expect(
      deleteButton.disabledColor,
      AppTheme.lightTextHint.withValues(alpha: 100 / 255),
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.delete_outline)).color,
      isNull,
    );

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

Future<void> _focusSemanticAction(WidgetTester tester, Finder action) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (tester.getSemantics(action).flagsCollection.isFocused ==
        Tristate.isTrue) {
      return;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  fail('Could not focus requested semantic action with keyboard traversal');
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

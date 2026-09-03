import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_android/screens/subscription_screen.dart';
import 'package:ssrvpn_android/services/clash_service.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
import 'package:ssrvpn_android/utils/responsive.dart';
import 'package:ssrvpn_android/widgets/subscription_network_error_dialog.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SubscriptionService.resetInstanceForTesting);

  Widget host(
    Widget child, {
    Size size = const Size(430, 900),
    double textScaleFactor = 1,
  }) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScaleFactor),
        ),
        child: Builder(
          builder: (context) {
            Responsive.init(context);
            return Scaffold(body: child);
          },
        ),
      ),
    );
  }

  testWidgets('subscription surface has no about action and adds links',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: const [],
          urlController: controller,
          isAdding: false,
          isRefreshing: false,
          isBusy: false,
          refreshMessage: null,
          refreshMessageColor: null,
          onAdd: () => submissions++,
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
      ),
    );

    expect(find.text('订阅管理'), findsOneWidget);
    expect(find.text('支持订阅链接与 ssr:// 导入'), findsOneWidget);
    expect(find.text('关于'), findsNothing);
    expect(find.text('暂无订阅'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('ssrvpn-subscription-input')),
      'https://example.com/sub',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.byKey(const Key('ssrvpn-subscription-add')));
    expect(submissions, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Android subscription keeps a textual logs action on compact large text',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('ssrvpn-sub-logs-');
    final subscriptionService = (await tester.runAsync(
      () => SubscriptionService.getInstance(directory.path),
    ))!;
    addTearDown(() {
      subscriptionService.dispose();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SubscriptionService>.value(
            value: subscriptionService,
          ),
          Provider<ClashService>.value(value: _TestDiagnosticsClashService()),
        ],
        child: host(
          const SubscriptionScreen(),
          size: const Size(320, 568),
          textScaleFactor: 2,
        ),
      ),
    );
    await tester.pump();

    final logsButton = find.byKey(
      const Key('ssrvpn-subscription-logs-button'),
    );
    expect(logsButton, findsOneWidget);
    expect(find.text('运行日志'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(logsButton);
    await tester.pumpAndSettle();
    expect(find.text('诊断与运行日志'), findsOneWidget);
  });

  testWidgets('subscription surface renders safe status and actions',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var refreshes = 0;
    String? deletedId;
    final subscription = Subscription(
      id: 'primary',
      name: '主订阅',
      url: 'https://user:password@example.com/sub?token=top-secret',
      lastUpdate: DateTime.now().subtract(const Duration(minutes: 5)),
    );

    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: [subscription],
          urlController: controller,
          isAdding: false,
          isRefreshing: false,
          isBusy: false,
          refreshMessage: '刷新成功',
          refreshMessageColor: SsrvpnUiTokens.success,
          onAdd: () {},
          onRefresh: () => refreshes++,
          onCancelRefresh: () {},
          onDelete: (id) => deletedId = id,
        ),
      ),
    );

    final subscriptionInput = tester.widget<TextField>(
      find.byKey(const Key('ssrvpn-subscription-input')),
    );
    expect(subscriptionInput.keyboardType, TextInputType.text);
    expect(subscriptionInput.autocorrect, isFalse);
    expect(subscriptionInput.enableSuggestions, isFalse);
    expect(find.text('主订阅'), findsOneWidget);
    expect(find.text('刷新成功'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.textContaining('top-secret'), findsNothing);
    expect(find.textContaining('password'), findsNothing);
    expect(find.textContaining('***'), findsOneWidget);
    await tester.tap(find.text('全部刷新'));
    await tester.tap(find.byTooltip('删除订阅'));
    expect(refreshes, 1);
    expect(deletedId, 'primary');
    expect(tester.takeException(), isNull);
  });

  testWidgets('network refresh guidance is transport-neutral and redacted',
      (tester) async {
    await tester.pumpWidget(
      host(
        const SubscriptionNetworkErrorDialog(
          detail:
              'failed https://user:password@example.com/sub?token=top-secret',
        ),
      ),
    );

    expect(find.text('订阅刷新失败'), findsOneWidget);
    expect(
      find.text('请确认设备已联网，并检查订阅地址或服务状态后重试'),
      findsOneWidget,
    );
    expect(find.textContaining('移动数据'), findsNothing);
    expect(find.textContaining('连接 WiFi'), findsNothing);
    expect(find.textContaining('top-secret'), findsNothing);
    expect(find.textContaining('password'), findsNothing);
    expect(find.textContaining('***'), findsOneWidget);
  });

  testWidgets(
      'network refresh dialog scrolls large details and keeps confirm reachable',
      (tester) async {
    await tester.pumpWidget(
      host(
        SubscriptionNetworkErrorDialog(
          detail: List.generate(
            40,
            (index) => '订阅 $index: Socket timeout '
                'https://user:password@example.com/path-secret-$index?token=secret-$index',
          ).join('\n'),
        ),
        size: const Size(320, 568),
        textScaleFactor: 2,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('ssrvpn-subscription-error-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('ssrvpn-subscription-error-confirm')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const Key('ssrvpn-subscription-error-confirm')),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class _TestDiagnosticsClashService extends ClashService {
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];
}

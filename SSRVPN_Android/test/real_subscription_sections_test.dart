import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
import 'package:ssrvpn_android/utils/responsive.dart';
import 'package:ssrvpn_android/widgets/subscription_screen_sections.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  Widget host(Widget child, {ThemeMode themeMode = ThemeMode.light}) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: Builder(
        builder: (context) {
          Responsive.init(context);
          return Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }

  testWidgets('subscription header exposes the supported import surface',
      (tester) async {
    var aboutTaps = 0;
    await tester.pumpWidget(
      host(
        SubscriptionHeader(
          isDark: false,
          onAboutTap: () => aboutTaps++,
        ),
      ),
    );

    expect(find.text('订阅管理'), findsOneWidget);
    expect(find.text('支持订阅链接与 ssr:// 导入'), findsOneWidget);
    expect(find.byIcon(Icons.rss_feed), findsOneWidget);

    await tester.tap(find.text('关于'));
    expect(aboutTaps, 1);

    await tester.pumpWidget(
      host(
        SubscriptionHeader(isDark: true, onAboutTap: () {}),
        themeMode: ThemeMode.dark,
      ),
    );
    expect(find.text('订阅管理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add card submits entered links from keyboard and button',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      host(
        SubscriptionAddCard(
          isDark: false,
          urlController: controller,
          isAdding: false,
          isBusy: false,
          onAdd: () => submissions++,
        ),
      ),
    );

    expect(find.text('添加订阅'), findsOneWidget);
    expect(find.text('粘贴订阅链接或 ssr:// 链接'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'https://example.com/sub');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(controller.text, 'https://example.com/sub');
    expect(submissions, 1);

    await tester.tap(find.widgetWithText(ElevatedButton, '添加'));
    expect(submissions, 2);
  });

  testWidgets('add card blocks duplicate submission while adding',
      (tester) async {
    final controller = TextEditingController(text: 'ssr://encoded');
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      host(
        SubscriptionAddCard(
          isDark: true,
          urlController: controller,
          isAdding: true,
          isBusy: true,
          onAdd: () => submissions++,
        ),
        themeMode: ThemeMode.dark,
      ),
    );

    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(submissions, 0);
  });

  testWidgets(
      'add card blocks keyboard and button while another operation runs',
      (tester) async {
    final controller = TextEditingController(text: 'https://example.com/sub');
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      host(
        SubscriptionAddCard(
          isDark: false,
          urlController: controller,
          isAdding: false,
          isBusy: true,
          onAdd: () => submissions++,
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(field.enabled, isFalse);
    expect(field.onSubmitted, isNull);
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(submissions, 0);
  });

  testWidgets('empty subscription state gives an actionable next step',
      (tester) async {
    await tester.pumpWidget(host(const SubscriptionEmptyState(isDark: false)));

    expect(find.text('暂无订阅'), findsOneWidget);
    expect(find.text('在上方粘贴订阅链接开始使用'), findsOneWidget);
    expect(find.byIcon(Icons.rss_feed), findsOneWidget);

    await tester.pumpWidget(
      host(
        const SubscriptionEmptyState(isDark: true),
        themeMode: ThemeMode.dark,
      ),
    );
    expect(find.text('暂无订阅'), findsOneWidget);
  });

  testWidgets('network refresh guidance does not guess the active transport',
      (tester) async {
    await tester.pumpWidget(
      host(
        const SubscriptionNetworkErrorDialog(
          detail: 'Connection reset by peer',
        ),
      ),
    );

    expect(find.text('订阅刷新失败'), findsOneWidget);
    expect(
      find.text('请确认设备已联网，并检查订阅地址或服务状态后重试'),
      findsOneWidget,
    );
    expect(find.text('Connection reset by peer'), findsOneWidget);
    expect(find.textContaining('移动数据'), findsNothing);
    expect(find.textContaining('连接 WiFi'), findsNothing);
  });

  testWidgets('network refresh guidance redacts credentials and tokens',
      (tester) async {
    await tester.pumpWidget(
      host(
        const SubscriptionNetworkErrorDialog(
          detail:
              'failed https://user:password@example.com/sub?token=top-secret',
        ),
      ),
    );

    expect(find.textContaining('top-secret'), findsNothing);
    expect(find.textContaining('password'), findsNothing);
    expect(find.textContaining('***'), findsOneWidget);
  });

  testWidgets('subscription list renders status, age, refresh and deletion',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now();
    final subscriptions = [
      Subscription(
        id: 'enabled-now',
        name: '主订阅',
        url: 'https://example.com/main',
        lastUpdate: now,
      ),
      Subscription(
        id: 'disabled-minutes',
        name: '备用订阅',
        url: 'https://example.com/backup',
        enabled: false,
        lastUpdate: now.subtract(const Duration(minutes: 5)),
      ),
      Subscription(
        id: 'hours',
        name: '小时订阅',
        url: 'https://example.com/hours',
        lastUpdate: now.subtract(const Duration(hours: 2)),
      ),
      Subscription(
        id: 'days',
        name: '天数订阅',
        url: 'https://example.com/days',
        lastUpdate: now.subtract(const Duration(days: 3)),
      ),
      Subscription(
        id: 'never',
        name: '从未更新',
        url: 'https://example.com/never',
      ),
      Subscription(
        id: 'old',
        name: '历史订阅',
        url: 'https://example.com/old',
        lastUpdate: DateTime(2024, 1, 2, 3, 4),
      ),
    ];
    var refreshes = 0;
    String? deletedId;

    await tester.pumpWidget(
      host(
        SubscriptionListSection(
          subscriptions: subscriptions,
          isDark: false,
          isAdding: false,
          isRefreshing: false,
          isDeleting: false,
          refreshResult: const SubscriptionRefreshResult(
            message: '6 个订阅全部刷新成功',
            status: SubscriptionRefreshStatus.success,
          ),
          onRefresh: () => refreshes++,
          onCancelRefresh: () {},
          onDelete: (id) => deletedId = id,
        ),
      ),
    );

    expect(find.text('我的订阅'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('6 个订阅全部刷新成功'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('已启用'), findsNWidgets(5));
    expect(find.text('已禁用'), findsOneWidget);
    expect(find.text('更新于 刚刚'), findsOneWidget);
    expect(find.text('更新于 5分钟前'), findsOneWidget);
    expect(find.text('更新于 2小时前'), findsOneWidget);
    expect(find.text('更新于 3天前'), findsOneWidget);
    expect(find.text('未更新'), findsOneWidget);
    expect(find.text('更新于 1/2 3:04'), findsOneWidget);

    await tester.tap(find.text('全部刷新'));
    expect(refreshes, 1);
    await tester.tap(find.byTooltip('删除订阅').first);
    expect(deletedId, 'enabled-now');
  });

  testWidgets('subscription list never renders URL credentials or tokens',
      (tester) async {
    const secretUrl =
        'https://user:password@example.com/api/subscription?token=top-secret';
    await tester.pumpWidget(
      host(
        SubscriptionListSection(
          subscriptions: [
            Subscription(
              id: 'sensitive',
              name: '私密订阅',
              url: secretUrl,
            ),
          ],
          isDark: false,
          isAdding: false,
          isRefreshing: false,
          isDeleting: false,
          refreshResult: null,
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
      ),
    );

    expect(find.text('https://example.com/***'), findsOneWidget);
    expect(find.text(secretUrl), findsNothing);
    expect(find.textContaining('top-secret'), findsNothing);
    expect(find.textContaining('password'), findsNothing);
  });

  testWidgets('refresh states distinguish partial and total failure',
      (tester) async {
    const partial = SubscriptionRefreshResult(
      message: '部分订阅刷新成功',
      status: SubscriptionRefreshStatus.partialSuccess,
    );
    var cancellations = 0;
    await tester.pumpWidget(
      host(
        SubscriptionListSection(
          subscriptions: const [],
          isDark: true,
          isAdding: false,
          isRefreshing: true,
          isDeleting: true,
          refreshResult: partial,
          onRefresh: () {},
          onCancelRefresh: () => cancellations++,
          onDelete: (_) {},
        ),
        themeMode: ThemeMode.dark,
      ),
    );

    expect(find.text('取消刷新'), findsOneWidget);
    expect(find.text('部分订阅刷新成功'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    final refreshButton =
        tester.widget<TextButton>(find.byType(TextButton).first);
    expect(refreshButton.onPressed, isNotNull);
    await tester.tap(find.text('取消刷新'));
    expect(cancellations, 1);

    await tester.pumpWidget(
      host(
        SubscriptionListSection(
          subscriptions: [
            Subscription(
              id: 'deleting',
              name: '正在删除',
              url: 'https://example.com/deleting',
            ),
          ],
          isDark: false,
          isAdding: false,
          isRefreshing: false,
          isDeleting: true,
          refreshResult: const SubscriptionRefreshResult(
            message: '订阅刷新失败',
            status: SubscriptionRefreshStatus.failure,
          ),
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
      ),
    );

    expect(find.text('订阅刷新失败'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byTooltip('删除订阅'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('subscription list blocks refresh and delete while adding',
      (tester) async {
    var refreshes = 0;
    var deletes = 0;
    await tester.pumpWidget(
      host(
        SubscriptionListSection(
          subscriptions: [
            Subscription(
              id: 'busy',
              name: '正在添加',
              url: 'https://example.com/busy',
            ),
          ],
          isDark: false,
          isAdding: true,
          isRefreshing: false,
          isDeleting: false,
          refreshResult: null,
          onRefresh: () => refreshes++,
          onCancelRefresh: () {},
          onDelete: (_) => deletes++,
        ),
      ),
    );

    final refreshButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '全部刷新'));
    expect(refreshButton.onPressed, isNull);
    expect(find.byTooltip('删除订阅'), findsNothing);
    expect(refreshes, 0);
    expect(deletes, 0);
  });
}

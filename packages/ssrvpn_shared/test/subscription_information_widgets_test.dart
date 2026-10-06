import 'package:flutter/cupertino.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_time_picker.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/models/subscription_usage.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_traffic_panel.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_edit_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_schedule_dialog.dart';

class _Service extends SubscriptionServiceBase {
  @override
  List<Subscription> get subscriptions => [
        Subscription(id: 'a', name: '示例订阅', url: 'https://example.invalid/sub'),
        Subscription(
            id: 'b',
            name: '停用订阅',
            url: 'https://other.invalid/sub',
            enabled: false),
        Subscription(
            id: 'local', name: '手动节点', url: 'trojan://fixture@node.invalid:443')
      ];
  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      null;
}

Future<void> capture(WidgetTester tester, String name) async {
  final output = Platform.environment['SSRVPN_SUBSCRIPTION_PREVIEW'];
  if (output == null) return;
  final boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(const Key('preview')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['SSRVPN_SUBSCRIPTION_PREVIEW'] == null) return;
    final file = File('/System/Library/Fonts/STHeiti Medium.ttc');
    await (FontLoader('PreviewCJK')
          ..addFont(
              Future.value(ByteData.sublistView(await file.readAsBytes()))))
        .load();
  });
  testWidgets(
      'in-app time wheels confirm midnight and cancel without changing time',
      (tester) async {
    TimeOfDay? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      selected = await showSubscriptionTimePicker(
                          context, const TimeOfDay(hour: 9, minute: 30));
                    },
                    child: const Text('选择时间'))))));
    await tester.tap(find.text('选择时间'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
    final hours = tester.widget<CupertinoPicker>(
        find.byKey(const ValueKey('subscription-time-小时')));
    final minutes = tester.widget<CupertinoPicker>(
        find.byKey(const ValueKey('subscription-time-分钟')));
    hours.scrollController!.jumpToItem(0);
    minutes.scrollController!.jumpToItem(0);
    await tester.pumpAndSettle();
    expect(find.text('00:00'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected, const TimeOfDay(hour: 0, minute: 0));
    await tester.tap(find.text('选择时间'));
    await tester.pumpAndSettle();
    expect(find.text('09:30'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final theme in AppThemeVariant.values) {
    for (final fields in ['both', 'usage', 'expiry', 'missing']) {
      testWidgets(
          '${theme.name} subscription $fields on narrow large-text screen',
          (tester) async {
        final usage = fields == 'missing'
            ? null
            : SubscriptionUsage(
                upload: fields == 'expiry' ? null : 0,
                download: fields == 'expiry' ? null : 0,
                total: 100 * 1024 * 1024 * 1024,
                expire: fields == 'usage' ? null : 1793894400,
                updatedAt: DateTime(2026, 10, 6));
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(fontFamily: 'PreviewCJK'),
            builder: (context, child) => MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: SsrvpnAppearanceScope(
                    settings: AppSettings(themeVariant: theme), child: child!)),
            home: Scaffold(
                body: RepaintBoundary(
                    key: const Key('preview'),
                    child: Center(
                        child: SizedBox(
                            width: 284,
                            height: 220,
                            child: SsrvpnHomeTrafficPanel(
                                active: false,
                                connected: false,
                                readSample: () async => null,
                                subscriptionUsage: usage)))))));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('已连接设备'), findsNothing);
        expect(find.text('每月1日重置'), findsNothing);
        if (fields == 'expiry' || fields == 'both') {
          expect(find.textContaining('到期时间'), findsWidgets);
        }
        if (fields == 'usage' || fields == 'both') {
          expect(find.textContaining('100 GiB'), findsWidgets);
        }
        if (fields == 'both') await capture(tester, theme.name);
        for (final element in find.byType(RichText).evaluate()) {
          final paragraph = element.renderObject as RenderParagraph;
          expect(paragraph.didExceedMaxLines, isFalse,
              reason: '${theme.name}: ${paragraph.text.toPlainText()}');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets(
      'schedule dialog excludes local nodes, saves weekly selections and cancels draft',
      (tester) async {
    final service = _Service();
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('schedule-ui-');
      await service.init(dir.path);
    });
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'PreviewCJK'),
        home: SsrvpnAppearanceScope(
            settings: AppSettings(),
            child:
                Scaffold(body: SubscriptionScheduleTile(service: service)))));
    await tester.tap(find.text('自动更新订阅'));
    await tester.pumpAndSettle();
    expect(find.text('手动节点'), findsNothing);
    expect(find.text('示例订阅'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-sub-a')));
    await tester.pump();
    await tester.tap(find.text('每天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('周三'));
    await tester.tap(find.text('周三'));
    await tester.pump();
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('schedule-sub-a')))
            .value,
        isTrue);
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 20 && service.autoUpdater.schedule == null; i++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
    }
    await tester.pumpAndSettle();
    expect(service.autoUpdater.schedule!.subscriptionIds, {'a'});
    expect(service.autoUpdater.schedule!.weekdays, {3});
    await tester.tap(find.text('自动更新订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-sub-b')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.autoUpdater.schedule!.subscriptionIds, {'a'});
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  testWidgets(
      'subscription editor returns proxy preference with unchanged name and URL',
      (tester) async {
    SsrvpnSubscriptionEditDraft? draft;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      draft = await showSsrvpnSubscriptionEditDialog(
                          context,
                          Subscription(
                              id: 'a',
                              name: 'Feed',
                              url: 'https://feed.invalid/sub'));
                    },
                    child: const Text('编辑'))))));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ssrvpn-subscription-edit-save')));
    await tester.pumpAndSettle();
    expect(draft!.refreshViaProxy, isTrue);
    expect(draft!.name, 'Feed');
  });
}

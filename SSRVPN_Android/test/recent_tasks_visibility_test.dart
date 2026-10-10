import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/recent_tasks_service.dart';
import 'package:ssrvpn_android/widgets/recent_tasks_visibility_tile.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show AppSettings, ClashServiceBase;
import 'package:ssrvpn_shared/widgets/ssrvpn_settings_page.dart';

class _Core extends Fake implements ClashServiceBase {
  @override
  bool get isRunning => true;
  @override
  int get runtimeProxyPort => 7890;
  @override
  void addStatusListener(VoidCallback listener) {}
  @override
  void removeStatusListener(VoidCallback listener) {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ssrvpn/recent_tasks');
  late bool saved;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handler;

  setUp(() {
    saved = false;
    calls = [];
    handler = (call) async {
      if (call.method == 'setEnabled') saved = call.arguments as bool;
      return saved;
    };
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  });
  tearDown(() =>
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
      const MaterialApp(
          home: Scaffold(
              body:
                  SingleChildScrollView(child: RecentTasksVisibilityTile()))));
  SwitchListTile tile(WidgetTester tester) =>
      tester.widget(find.byType(SwitchListTile));

  testWidgets(
      'loads, toggles both directions, and reloads persisted native state',
      (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    expect(tile(tester).value, isFalse);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(tile(tester).value, isTrue);
    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    await tester.pumpAndSettle();
    expect(tile(tester).value, isTrue);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(saved, isFalse);
    expect(tile(tester).value, isFalse);
  });

  testWidgets(
      'pending requests keep the confirmed value and reject double taps',
      (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    final pending = Completer<Object?>();
    handler = (_) => pending.future;
    tile(tester).onChanged!(true);
    tile(tester).onChanged!(true);
    await tester.pump();
    expect(tile(tester).value, isFalse);
    expect(tile(tester).onChanged, isNull);
    expect(calls.where((call) => call.method == 'setEnabled'), hasLength(1));
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(tile(tester).value, isTrue);
  });

  testWidgets('write failure rereads actual state and gives a retry action',
      (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    handler = (call) async {
      if (call.method == 'setEnabled') {
        throw PlatformException(code: 'RECENTS_VISIBILITY_FAILED');
      }
      return false;
    };
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(tile(tester).value, isFalse);
    expect(find.text('设置未能完成，请重试。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    handler = (_) async => true;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(tile(tester).value, isTrue);
    expect(find.text('设置未能完成，请重试。'), findsNothing);
  });

  testWidgets('unknown state disables the switch until a successful retry',
      (tester) async {
    handler = (_) async => throw PlatformException(code: 'UNAVAILABLE');
    await mount(tester);
    await tester.pumpAndSettle();
    expect(tile(tester).onChanged, isNull);
    expect(find.text('无法读取系统设置，请重试。'), findsOneWidget);
    handler = (_) async => true;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(tile(tester).value, isTrue);
    expect(tile(tester).onChanged, isNotNull);
  });

  testWidgets(
      'write plus recovery failure does not claim the previous state is saved',
      (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    handler = (_) async => throw PlatformException(code: 'UNAVAILABLE');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(tile(tester).onChanged, isNull);
    expect(find.text('设置未能完成，请重试。'), findsOneWidget);
  });

  testWidgets(
      'a late response after leaving the page cannot update a disposed widget',
      (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    final pending = Completer<Object?>();
    handler = (_) => pending.future;
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('resuming reconciles a system-side preference change',
      (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    saved = true;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tile(tester).value, isTrue);
  });

  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('application section stays usable at text scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Scaffold(
            body: SsrvpnSettingsPage(
          settings: AppSettings(),
          core: _Core(),
          applicationSettings: const [RecentTasksVisibilityTile()],
          onAppearanceChanged: ({themeVariant}) async {},
          onPortChanged: (_) async {},
          checkForUpdate: () async => null,
          onUpdateFound: (_) {},
        )),
      ));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('hide-from-recents')), 150,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('隐藏后台'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tile(tester).onChanged!(true);
      await tester.pumpAndSettle();
      expect(tile(tester).value, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  test('null and malformed native results are rejected', () async {
    handler = (_) async => null;
    await expectLater(const RecentTasksService().read(), throwsStateError);
    handler = (_) async => 'true';
    await expectLater(
        const RecentTasksService().setEnabled(true), throwsA(isA<TypeError>()));
  });
}

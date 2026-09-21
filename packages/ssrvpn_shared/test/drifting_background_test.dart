import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_drifting_background.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';

void main() {
  testWidgets(
      'page transition freezes wallpaper without disabling page animation',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()));
    final route = SsrvpnGlassPageRoute<void>(
        builder: (_) => const SsrvpnDriftingBackground(
            drift: true, child: ColoredBox(color: Colors.blue)));
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    Offset position() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    final initial = position();
    await tester.pump(const Duration(milliseconds: 160));
    expect(route.animation!.value, inExclusiveRange(0, 1));
    expect(position(), initial);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 2));
    expect(position(), isNot(initial));
    navigator.currentState!.pop();
    await tester.pump();
    final reverse = position();
    await tester.pump(const Duration(milliseconds: 100));
    expect(position(), reverse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('popup pauses obscured wallpaper and resumes at the same phase',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    late BuildContext routeContext;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      routeContext = context;
      return const SsrvpnDriftingBackground(
          drift: true, child: ColoredBox(color: Colors.blue));
    })));
    Offset position() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    await tester.pump(const Duration(seconds: 4));
    final before = position();
    final dialog = showDialog<void>(
        context: routeContext, builder: (_) => const Dialog(child: Text('弹窗')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(position(), before);
    Navigator.of(routeContext).pop();
    await tester.pump();
    expect(position(), before);
    await tester.pump(const Duration(seconds: 4));
    expect(position(), isNot(before));
    await dialog;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wallpaper moves only while resumed and respects reduced motion',
      (tester) async {
    Widget page({bool reduce = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
                disableAnimations: reduce, accessibleNavigation: true),
            child: const SsrvpnDriftingBackground(
                drift: true, child: ColoredBox(color: Colors.blue)),
          ),
        );
    Offset position() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(page());
    final initial = position();
    await tester.pump(const Duration(seconds: 6));
    expect(position(), isNot(initial));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final inactive = position();
    await tester.pump(const Duration(seconds: 6));
    expect(position(), inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final paused = position();
    await tester.pump(const Duration(seconds: 6));
    expect(position(), paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(page(reduce: true));
    final reduced = position();
    await tester.pump(const Duration(seconds: 6));
    expect(position(), reduced);
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(tester.takeException(), isNull);
  });
  testWidgets('turnaround and cycle seam stay continuous', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const MaterialApp(
        home: SsrvpnDriftingBackground(
            drift: true, child: ColoredBox(color: Colors.blue))));
    Offset position() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    await tester.pump(const Duration(milliseconds: 8990));
    final beforeTurn = position();
    await tester.pump(const Duration(milliseconds: 20));
    expect((position() - beforeTurn).distance, lessThan(.000001));
    await tester.pump(const Duration(milliseconds: 8980));
    final beforeSeam = position();
    await tester.pump(const Duration(milliseconds: 20));
    expect((position() - beforeSeam).distance, lessThan(.000001));
    final beforePause = position();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect((position() - beforePause).distance, lessThan(.000001));
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
  });
  testWidgets(
      'stronger wallpaper motion stays covered through the 18 second cycle',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const MaterialApp(
        home: SsrvpnDriftingBackground(
      drift: true,
      child: ColoredBox(key: Key('wallpaper'), color: Colors.blue),
    )));
    final initial = tester.getRect(find.byKey(const Key('wallpaper')));
    await tester.pump(const Duration(seconds: 4));
    final moved = tester.getRect(find.byKey(const Key('wallpaper')));
    expect((moved.left - initial.left).abs(), greaterThan(10));
    for (final seconds in [0, 5, 4, 5]) {
      await tester.pump(Duration(seconds: seconds));
      final rect = tester.getRect(find.byKey(const Key('wallpaper')));
      expect(rect.left, lessThanOrEqualTo(0));
      expect(rect.top, lessThanOrEqualTo(0));
      expect(rect.right, greaterThanOrEqualTo(390));
      expect(rect.bottom, greaterThanOrEqualTo(844));
    }
    final seam = tester.getRect(find.byKey(const Key('wallpaper')));
    expect(seam.left, closeTo(initial.left, .01));
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
  });
  testWidgets('a still wallpaper holds its framing and schedules no frame',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const MaterialApp(
        home: SsrvpnDriftingBackground(
            drift: false, child: ColoredBox(color: Colors.blue))));
    Offset position() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    await tester.pump();
    final frozen = position();
    expect(tester.binding.hasScheduledFrame, isFalse, reason: '静默壁纸不应再请求任何一帧');
    await tester.pump(const Duration(seconds: 6));
    expect(position(), frozen);
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(tester.takeException(), isNull);
  });
  testWidgets('the preference freezes in place and resumes from there',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Widget page({required bool drift}) => MaterialApp(
        home: SsrvpnDriftingBackground(
            drift: drift, child: const ColoredBox(color: Colors.blue)));
    Offset position() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    await tester.pumpWidget(page(drift: true));
    await tester.pump(const Duration(seconds: 4));
    final drifting = position();
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(page(drift: false));
    await tester.pump();
    final frozen = position();
    expect(frozen, drifting, reason: '关闭时停在当前相位，不跳回起点');
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 6));
    expect(position(), frozen);
    await tester.pumpWidget(page(drift: true));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(position(), isNot(frozen));
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(tester.takeException(), isNull);
  });
}

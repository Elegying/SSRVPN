import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_drifting_background.dart';

void main() {
  testWidgets('popup pauses obscured wallpaper and resumes at the same phase',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    late BuildContext routeContext;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      routeContext = context;
      return const SsrvpnDriftingBackground(
          child: ColoredBox(color: Colors.blue));
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
                child: ColoredBox(color: Colors.blue)),
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
        home: SsrvpnDriftingBackground(child: ColoredBox(color: Colors.blue))));
    Offset position() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    await tester.pump(const Duration(milliseconds: 15990));
    final beforeTurn = position();
    await tester.pump(const Duration(milliseconds: 20));
    expect((position() - beforeTurn).distance, lessThan(.000001));
    await tester.pump(const Duration(milliseconds: 15980));
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
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_glass.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_scroll_behavior.dart';

void main() {
  testWidgets('scrolling during page entry keeps live glass outside opacity',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      scrollBehavior: const SsrvpnScrollBehavior(),
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox();
      }),
    ));
    final route = SsrvpnGlassPageRoute<void>(
        builder: (_) => Scaffold(
              body: ListView.builder(
                  itemCount: 30,
                  itemBuilder: (_, index) => SsrvpnLiquidSurface(
                      child: SizedBox(height: 80, child: Text('$index')))),
            ));
    final previous = ModalRoute.of(context)!;
    Navigator.of(context).push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    await tester.timedDrag(find.byType(ListView), const Offset(0, -160),
        const Duration(milliseconds: 80));
    await tester.pump();
    expect(previous.secondaryAnimation!.value, 0);
    expect(route.allowSnapshotting, isFalse);
    expect(route.transitionDuration, const Duration(milliseconds: 320));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 260));
    expect(find.byType(Scrollbar), findsNothing);
    expect(
        find.ancestor(
            of: find.byType(SsrvpnLiquidSurface).first,
            matching: find.byType(FadeTransition)),
        findsNothing);
    expect(tester.takeException(), isNull);
    Navigator.of(context).pop();
    await tester.pump(const Duration(milliseconds: 100));
    expect(previous.secondaryAnimation!.value, 0);
    await tester.pumpAndSettle();
  });
}

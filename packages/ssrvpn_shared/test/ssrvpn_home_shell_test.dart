import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_shell.dart';

void main() {
  testWidgets('floating navigation reserves scroll tail and preserves the body',
      (tester) async {
    final extended = ValueNotifier(false);
    var builds = 0;
    late StateSetter updateBody;
    final body = StatefulBuilder(builder: (context, setState) {
      updateBody = setState;
      builds++;
      return SingleChildScrollView(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: const SizedBox(height: 1200, child: Text('subscription')),
      );
    });
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: extended,
        builder: (_, value, __) => SsrvpnHomeShell(
          extendBehindNavigation: value,
          body: body,
          navigation: const SizedBox(height: 100, child: Text('navigation')),
        ),
      ),
    ));
    final before = tester.state(find.byType(StatefulBuilder));
    extended.value = true;
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(StatefulBuilder)), same(before));
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.padding, const EdgeInsets.only(bottom: 100));
    expect(tester.getBottomRight(find.byType(SingleChildScrollView)).dy,
        tester.getBottomRight(find.byType(SsrvpnHomeShell)).dy);
    updateBody(() {});
    await tester.pump();
    expect(builds, greaterThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    extended.dispose();
  });
}

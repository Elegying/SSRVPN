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
  testWidgets('paged subscription keeps navigation inset through its scaffold',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final pageController = PageController(initialPage: 1);
    addTearDown(pageController.dispose);
    await tester.pumpWidget(MaterialApp(
      home: SsrvpnHomeShell(
        extendBehindNavigation: true,
        navigation: const SizedBox(height: 110, child: Text('navigation')),
        body: PageView(
          controller: pageController,
          children: [
            const SizedBox(),
            Scaffold(
              backgroundColor: Colors.transparent,
              body: Builder(
                  builder: (context) => SingleChildScrollView(
                        key: const Key('subscription-scroll'),
                        padding: EdgeInsets.only(
                            bottom: 30 + MediaQuery.paddingOf(context).bottom),
                        child: Column(
                            children: List.generate(
                                20,
                                (i) => SizedBox(
                                      height: 100,
                                      child: Text('subscription-$i'),
                                    ))),
                      )),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final scrollFinder = find.byKey(const Key('subscription-scroll'));
    final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
    expect(scroll.padding, const EdgeInsets.only(bottom: 140));
    expect(tester.getBottomRight(scrollFinder).dy, 844);
    await tester.drag(scrollFinder, const Offset(0, -2500));
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(find.text('subscription-19')).dy,
        lessThan(tester.getTopLeft(find.text('navigation')).dy));
    expect(tester.takeException(), isNull);
  });
  testWidgets('paged glass viewport and home height stay fixed across midpoint',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final pages = PageController();
    addTearDown(pages.dispose);
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
      builder: (context, update) => SsrvpnHomeShell(
        extendBehindNavigation: true,
        navigation: const SizedBox(height: 110),
        body: PageView(
          controller: pages,
          onPageChanged: (value) => update(() => selected = value),
          children: [
            Builder(builder: (pageContext) {
              final media = MediaQuery.of(pageContext);
              return Padding(
                padding: EdgeInsets.only(bottom: media.padding.bottom),
                child: MediaQuery(
                  data: media.copyWith(padding: MediaQuery.paddingOf(context)),
                  child: const ColoredBox(
                      key: Key('home-area'), color: Colors.blue),
                ),
              );
            }),
            const ColoredBox(
                key: Key('subscription-area'), color: Colors.purple),
          ],
        ),
      ),
    )));
    await tester.pumpAndSettle();
    final height = tester.getSize(find.byType(PageView)).height;
    expect(height, 844);
    expect(tester.getSize(find.byKey(const Key('home-area'))).height, 734);
    for (final fraction in [.25, .49, .51, .75, 1.0, .75, .49, .25, 0.0]) {
      pages.jumpTo(390 * fraction);
      await tester.pump();
      expect(tester.getSize(find.byType(PageView)).height, height);
      if (find.byKey(const Key('home-area')).evaluate().isNotEmpty) {
        expect(tester.getSize(find.byKey(const Key('home-area'))).height, 734);
      }
      expect(tester.takeException(), isNull);
    }
    expect(selected, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'inactive tab releases focus and stops tickers without losing state',
      (tester) async {
    final active = ValueNotifier(true);
    final focus = FocusNode();
    final input = TextEditingController(text: 'preserved input');
    addTearDown(active.dispose);
    addTearDown(focus.dispose);
    addTearDown(input.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, value, __) => SsrvpnPageActivity(
          active: value,
          child: Column(children: [
            TextField(focusNode: focus, controller: input),
            const CircularProgressIndicator(),
          ]),
        ),
      )),
    ));
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    final fieldState = tester.state(find.byType(TextField));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    active.value = false;
    await tester.pump();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    expect(input.text, 'preserved input');
    active.value = true;
    await tester.pump();
    expect(tester.state(find.byType(TextField)), same(fieldState));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

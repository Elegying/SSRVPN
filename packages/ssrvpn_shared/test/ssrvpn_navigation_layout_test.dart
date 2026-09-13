import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          '${platform.name} floating subscription tail at text scale $scale',
          (tester) async {
        final size = platform == TargetPlatform.android
            ? const Size(320, 568)
            : const Size(800, 720);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final input = TextEditingController();
        final pages = PageController(initialPage: 1);
        addTearDown(input.dispose);
        addTearDown(pages.dispose);
        final subscription = Scaffold(
          backgroundColor: Colors.transparent,
          body: SsrvpnSubscriptionView(
            subscriptions: List.generate(
                10,
                (i) => Subscription(
                      id: '$i',
                      name: 'subscription-$i',
                      url: 'https://example.invalid/sub',
                    )),
            urlController: input,
            isAdding: false,
            isRefreshing: false,
            isBusy: false,
            refreshMessage: null,
            refreshMessageColor: null,
            onAdd: () {},
            onRefresh: () {},
            onCancelRefresh: () {},
            onDelete: (_) {},
            onEdit: (_) {},
          ),
        );
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark().copyWith(platform: platform),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              padding: const EdgeInsets.only(top: 24, bottom: 24),
              viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
            ),
            child: child!,
          ),
          home: SsrvpnHomeShell(
            extendBehindNavigation: true,
            body: platform == TargetPlatform.android
                ? PageView(
                    controller: pages,
                    children: [const SizedBox(), subscription])
                : IndexedStack(
                    index: 1, children: [const SizedBox(), subscription]),
            navigation: SsrvpnBottomNavigation(
                currentIndex: 1, version: '5.0.0', onTap: (_) {}),
          ),
        ));
        await tester.pumpAndSettle();
        final scroll = find.byKey(const Key('ssrvpn-subscription-scroll'));
        expect(tester.getBottomRight(scroll).dy, size.height);
        await tester.scrollUntilVisible(find.text('subscription-9'), 400,
            scrollable: find
                .descendant(of: scroll, matching: find.byType(Scrollable))
                .first);
        final position = tester
            .state<ScrollableState>(find
                .descendant(of: scroll, matching: find.byType(Scrollable))
                .first)
            .position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
            tester.getBottomRight(find.text('subscription-9')).dy,
            lessThan(tester
                .getTopLeft(find.byKey(const Key('ssrvpn-bottom-navigation')))
                .dy));
        expect(find.byTooltip('编辑订阅').last.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

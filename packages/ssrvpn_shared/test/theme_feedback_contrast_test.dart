import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final variant in AppThemeVariant.values) {
    testWidgets('$variant version badge is opaque, compact and readable',
        (tester) async {
      final palette = SsrvpnTheme(variant);
      for (final sample in [(1.0, false), (2.0, true)]) {
        await tester.pumpWidget(MaterialApp(
          theme: palette.material(ThemeData()),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(sample.$1),
                  highContrast: sample.$2),
              child: child!),
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 320,
                      child: SsrvpnBottomNavigation(
                          currentIndex: 1,
                          version: '6.0.8',
                          availableVersion: sample.$2 ? '6.0.9' : null,
                          onUpdateTap: () {},
                          onTap: (_) {})))),
        ));
        await tester.pumpAndSettle();
        final badge = find.byKey(const Key('ssrvpn-version-badge'));
        final text = find.text('版本号：6.0.8');
        final decoration =
            tester.widget<DecoratedBox>(badge).decoration as BoxDecoration;
        final foreground = tester.widget<Text>(text).style!.color!;
        final background = decoration.color!;
        expect(background.a, 1);
        final a = foreground.computeLuminance(),
            b = background.computeLuminance();
        expect((a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05)),
            greaterThanOrEqualTo(4.5));
        expect(tester.getSize(badge).width,
            closeTo(tester.getSize(text).width + 12, .01));
        expect(tester.getSize(badge).height,
            closeTo(tester.getSize(text).height + 2, .01));
        if (sample.$1 == 1) {
          expect(tester.getSize(badge).height, lessThanOrEqualTo(18));
        }
        expect(tester.takeException(), isNull);
      }
    });
    test('$variant primary action label has normal-text contrast', () {
      final palette = SsrvpnTheme(variant);
      final a = palette.onPrimary.computeLuminance();
      final b = palette.primary.computeLuminance();
      final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });
    testWidgets('$variant feedback remains readable on status backgrounds',
        (tester) async {
      final palette = SsrvpnTheme(variant);
      for (final background in [
        palette.error,
        palette.warning,
        palette.success
      ]) {
        final messenger = GlobalKey<ScaffoldMessengerState>();
        await tester.pumpWidget(MaterialApp(
          key: UniqueKey(),
          scaffoldMessengerKey: messenger,
          theme: palette.material(ThemeData()),
          home: const Scaffold(body: SizedBox()),
        ));
        messenger.currentState!.showSnackBar(ssrvpnSnackBar(
            margin: const EdgeInsets.all(16),
            backgroundColor: background,
            content: const Text('保存失败，请重试')));
        await tester.pumpAndSettle();
        final foreground =
            DefaultTextStyle.of(tester.element(find.text('保存失败，请重试')))
                .style
                .color!;
        final a = foreground.computeLuminance();
        final b = background.computeLuminance();
        final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}

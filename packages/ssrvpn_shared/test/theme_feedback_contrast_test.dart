import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final variant in AppThemeVariant.values) {
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

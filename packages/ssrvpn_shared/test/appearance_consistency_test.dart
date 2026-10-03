import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_app_surface.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_overview.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_glass.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';

void main() {
  for (final variant in AppThemeVariant.values) {
    testWidgets(
        '${variant.name} carries palette through dialog/menu and power/navigation actions',
        (tester) async {
      var toggles = 0;
      var destination = 0;
      final settings = AppSettings(themeVariant: variant);
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) =>
              SsrvpnAppearanceScope(settings: settings, child: child!),
          home: Scaffold(
              body: Builder(
                  builder: (context) => Column(children: [
                        const SsrvpnLiquidSurface(child: Text('卡片')),
                        SsrvpnPowerButton(
                            size: 100,
                            isConnected: false,
                            isConnecting: false,
                            onTap: () => toggles++),
                        TextButton(
                            onPressed: () => showSsrvpnGlassDialog<void>(
                                context: context,
                                builder: (context) => SsrvpnLiquidAlertDialog(
                                        title: const Text('主题弹窗'),
                                        content: const Text('正文'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  dismissSsrvpnDialog<void>(
                                                      context),
                                              child: const Text('关闭')),
                                        ])),
                            child: const Text('打开')),
                        SsrvpnBottomNavigation(
                            currentIndex: 0,
                            version: 'test',
                            onTap: (index) => destination = index),
                      ])))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
      expect(toggles, 1);
      await tester.tap(find.text('设置'));
      expect(destination, 2);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('主题弹窗'));
      expect(SsrvpnTheme.of(context).variant, variant);
      expect(Theme.of(context).brightness,
          SsrvpnTheme(variant).isLight ? Brightness.light : Brightness.dark);
      expect(ssrvpnGlassQuality(context), glass.GlassQuality.premium);
      expect(ssrvpnGlassDisabled(context),
          variant != AppThemeVariant.defaultTheme);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

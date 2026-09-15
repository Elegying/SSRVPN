import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_app_surface.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_connection_halo.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_overview.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_glass.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';

void main() {
  test(
      'new colors persist independently and old custom image choice is unchanged',
      () {
    for (final style in BackgroundStyle.values) {
      expect(ssrvpnBackgroundLabel(style), isNotEmpty);
      final settings = AppSettings(
          backgroundStyle: style, customBackgroundPath: '/image.png');
      expect(AppSettings.fromJson(settings.toJson()).backgroundStyle, style);
    }
    expect(ssrvpnBackgroundColor(BackgroundStyle.black), Colors.black);
    expect(ssrvpnBackgroundColor(BackgroundStyle.deepBlue),
        isNot(ssrvpnBackgroundColor(BackgroundStyle.blue)));
    expect(AppSettings.fromJson({'backgroundStyle': 'custom'}).backgroundStyle,
        BackgroundStyle.custom);
  });
  for (final level in GlassEffectLevel.values) {
    testWidgets(
        '${level.name} keeps cards power button navigation and dialog on the same tier',
        (tester) async {
      final settings = AppSettings(glassEffectLevel: level);
      final low =
          level == GlassEffectLevel.none || level == GlassEffectLevel.low;
      final quality = low
          ? glass.GlassQuality.minimal
          : level == GlassEffectLevel.medium
              ? glass.GlassQuality.standard
              : glass.GlassQuality.premium;
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          builder: (_, child) =>
              SsrvpnAppearanceScope(settings: settings, child: child!),
          home: Scaffold(
              body: Builder(
                  builder: (context) => Column(children: [
                        const SsrvpnLiquidSurface(
                            key: Key('grade-card'), child: Text('卡片')),
                        SsrvpnPowerButton(
                            size: 100,
                            isConnected: true,
                            isConnecting: false,
                            onTap: () {}),
                        const SsrvpnFrostedPanel(child: Text('兼容表面')),
                        TextButton(
                            onPressed: () => showSsrvpnGlassDialog<void>(
                                context: context,
                                builder: (_) => const SsrvpnLiquidAlertDialog(
                                    title: Text('弹窗'), content: Text('内容'))),
                            child: const Text('打开')),
                        SsrvpnBottomNavigation(
                            currentIndex: 0, version: '5.0.2', onTap: (_) {}),
                      ])))));
      void verifySurfaces() {
        for (final element in find.byType(SsrvpnLiquidSurface).evaluate()) {
          expect(ssrvpnGlassQuality(element), quality);
          final optics = SsrvpnLiquidSurface.settingsFor(element);
          expect(optics.thickness, level == GlassEffectLevel.medium ? 12 : 30);
          expect(optics.lightIntensity,
              level == GlassEffectLevel.medium ? .51 : .85);
        }
        if (low) {
          expect(find.byType(glass.GlassContainer), findsNothing);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(
              tester
                  .widget<SsrvpnConnectionHalo>(
                      find.byType(SsrvpnConnectionHalo))
                  .enabled,
              isFalse);
        } else {
          final nav =
              tester.widget<glass.GlassTabBar>(find.byType(glass.GlassTabBar));
          expect(nav.quality, quality);
          expect(nav.backgroundQuality, quality);
        }
      }

      verifySurfaces();
      if (low) {
        final box = tester.widget<DecoratedBox>(find
            .descendant(
                of: find.byKey(const Key('grade-card')),
                matching: find.byType(DecoratedBox))
            .first);
        if (level == GlassEffectLevel.none) {
          expect((box.decoration as BoxDecoration).color!.a, 1);
        }
        if (level == GlassEffectLevel.low) {
          expect((box.decoration as BoxDecoration).color!.a, lessThan(1));
        }
      }
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('弹窗'), findsOneWidget);
      verifySurfaces();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

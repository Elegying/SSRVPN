import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_connection_art.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_theme.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_themed_power_button.dart';

void main() {
  final captureDir = Platform.environment['SSRVPN_MOTION_CAPTURE_DIR'];
  setUpAll(() async {
    if (captureDir == null) return;
    final loader = FontLoader('MaterialIcons');
    loader.addFont(
        File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf')
            .readAsBytes()
            .then(ByteData.sublistView));
    await loader.load();
  });
  for (final variant in [
    AppThemeVariant.aurora,
    AppThemeVariant.sakura,
    AppThemeVariant.dusk
  ]) {
    testWidgets('${variant.name} motion follows connection and visibility',
        (tester) async {
      var taps = 0;
      final capture = GlobalKey();
      Widget host(
              {bool connected = false,
              bool connecting = false,
              bool error = false,
              bool reduced = false,
              bool visible = true}) =>
          MaterialApp(
              theme: ThemeData(extensions: [SsrvpnTheme(variant)]),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: reduced),
                  child: child!),
              home: Scaffold(
                  body: Center(
                      child: TickerMode(
                          enabled: visible,
                          child: RepaintBoundary(
                              key: capture,
                              child: ColoredBox(
                                  color: SsrvpnTheme(variant).background,
                                  child: SsrvpnThemedPowerButton(
                                      size: 240,
                                      isConnected: connected,
                                      isConnecting: connecting,
                                      hasConnectionError: error,
                                      onTap: () => taps++)))))));
      AnimationController clock() => tester
          .widget<AnimatedBuilder>(find.descendant(
              of: find.byType(SsrvpnConnectionArtwork),
              matching: find.byType(AnimatedBuilder)))
          .animation as AnimationController;
      await tester.pumpWidget(host());
      expect(clock().isAnimating, isFalse);
      final center =
          tester.getCenter(find.byKey(const Key('ssrvpn-power-button')));
      await tester.pumpWidget(host(connected: true));
      await tester.pump(const Duration(seconds: 1));
      expect(clock().isAnimating, isTrue);
      expect(clock().value, greaterThan(0));
      expect(tester.getCenter(find.byKey(const Key('ssrvpn-power-button'))),
          center);
      await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
      expect(taps, 1);
      if (captureDir != null) {
        if (variant == AppThemeVariant.sakura) {
          await tester.runAsync(() => precacheImage(
              AssetImage('assets/themes/${variant.name}-control.webp',
                  package: 'ssrvpn_shared'),
              capture.currentContext!));
        }
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 500));
          final boundary = capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(captureDir).create(recursive: true);
            await File('$captureDir/${variant.name}-$frame.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.pumpWidget(host(connected: true, connecting: true));
      expect(clock().isAnimating, isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
      expect(taps, 2);
      await tester.pumpWidget(host(connected: true, error: true));
      expect(clock().isAnimating, isFalse);
      await tester.pumpWidget(host(connected: true, reduced: true));
      expect(clock().isAnimating, isFalse);
      await tester.pumpWidget(host(connected: true, visible: false));
      expect(clock().isAnimating, isFalse);
      await tester.pumpWidget(host(connected: true));
      expect(clock().isAnimating, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(clock().isAnimating, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(clock().isAnimating, isTrue);
      await tester.pumpWidget(host());
      expect(clock().isAnimating, isFalse);
      expect(clock().value, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

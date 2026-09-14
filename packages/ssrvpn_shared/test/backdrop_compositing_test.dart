import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_app_surface.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_drifting_background.dart';

void main() {
  testWidgets('integrated wallpaper tint preserves original pixels and layers',
      (tester) async {
    final captureKey = GlobalKey();
    const provider = AssetImage('assets/backgrounds/network-glass-deep.png',
        package: 'ssrvpn_shared');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() =>
        precacheImage(provider, tester.element(find.byType(SizedBox).first)));
    for (final size in [const Size(390, 844), const Size(844, 390)]) {
      await tester.binding.setSurfaceSize(size);
      for (final highContrast in [false, true]) {
        Future<List<int>> pixels(bool optimized) async {
          await tester.pumpWidget(MaterialApp(
              home: MediaQuery(
                  data: MediaQueryData(
                      highContrast: highContrast, disableAnimations: true),
                  child: RepaintBoundary(
                      key: captureKey,
                      child: optimized
                          ? const SsrvpnAppBackdrop(child: SizedBox())
                          : Stack(fit: StackFit.expand, children: [
                              const SsrvpnDriftingBackground(
                                  child: Image(
                                      image: provider,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.center,
                                      filterQuality: FilterQuality.medium)),
                              ColoredBox(
                                  color: Colors.black.withValues(
                                      alpha: highContrast ? .65 : .28)),
                            ])))));
          await tester.pump();
          final boundary = captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await tester.runAsync(() => boundary.toImage());
          final data = await tester.runAsync(
              () => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
          image!.dispose();
          return data!.buffer.asUint8List();
        }

        final original = await pixels(false);
        final optimized = await pixels(true);
        expect(optimized.length, original.length);
        var maxDifference = 0;
        for (var i = 0; i < original.length; i++) {
          final difference = (optimized[i] - original[i]).abs();
          if (difference > maxDifference) maxDifference = difference;
        }
        expect(maxDifference, lessThanOrEqualTo(1),
            reason: 'Only 8-bit rounding may differ: $size / $highContrast');
        // The color filter belongs to the image paint, not a saveLayer widget.
        expect(find.byType(ColorFiltered), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}

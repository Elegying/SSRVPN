import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_dusk_dial.dart';

void main() {
  for (final size in [
    const Size(240, 240),
    const Size(180, 260),
    const Size(320, 180)
  ]) {
    testWidgets('dusk halo pixel mass stays centered at $size', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
          home: Center(
              child: RepaintBoundary(
        key: key,
        child: SizedBox.fromSize(size: size, child: const SsrvpnDuskDial()),
      ))));
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 3);
        final pixels =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        double mass = 0, xMass = 0, yMass = 0;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            final alpha = pixels!.getUint8((y * image.width + x) * 4 + 3);
            mass += alpha;
            xMass += alpha * (x + .5);
            yMass += alpha * (y + .5);
          }
        }
        // Subpixel blur kernels can shift alpha mass by less than a pixel.
        // At 3x, allow at most a quarter logical pixel, never a visible offset.
        expect(mass, greaterThan(0));
        expect(xMass / mass / 3, closeTo(size.width / 2, .25));
        expect(yMass / mass / 3, closeTo(size.height / 2, .25));
        image.dispose();
      });
    });
  }
}

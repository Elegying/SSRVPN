import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:liquid_glass_widgets/utils/glass_quality_adapter.dart';

void main() {
  testWidgets('fixed optical quality does not start a frame timing monitor',
      (tester) async {
    for (final quality in glass.GlassQuality.values) {
      final adapter = GlassQualityAdapter(
        minQuality: quality,
        maxQuality: quality,
        initialQuality: quality,
        targetFrameMs: 16,
        allowStepUp: false,
        onQualityChanged: (_, __) {},
      );
      adapter.start();
      expect(adapter.isRunning, isFalse);
      adapter.stop();
    }
  });

  testWidgets('glass repaints retain layers and preserve pixels',
      (tester) async {
    await tester.runAsync(glass.LightweightLiquidGlass.preWarm);
    final captureKey = GlobalKey();
    Future<List<int>> pixels() async {
      final boundary = captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final data = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
      image!.dispose();
      return data!.buffer.asUint8List();
    }

    final repaint = ValueNotifier<int>(0);
    addTearDown(repaint.dispose);
    Widget scene() {
      final cards = ValueListenableBuilder<int>(
        valueListenable: repaint,
        builder: (_, value, __) => Column(children: [
          for (var i = 0; i < 2; i++)
            Padding(
              padding: const EdgeInsets.all(20),
              child: glass.LightweightLiquidGlass(
                settings: const glass.LiquidGlassSettings(blur: 5),
                shape: const glass.LiquidRoundedSuperellipse(borderRadius: 12),
                child: SizedBox(width: 200, height: 60, child: Text('$value')),
              ),
            ),
        ]),
      );
      return MaterialApp(
          home: Scaffold(
              body: Stack(children: [
        const Positioned.fill(
            child: DecoratedBox(
                decoration: BoxDecoration(
          gradient: LinearGradient(colors: [Colors.blue, Colors.purple]),
        ))),
        cards,
      ])));
    }

    await tester.pumpWidget(RepaintBoundary(key: captureKey, child: scene()));
    await tester.pump();
    final initialPixels = await pixels();
    final layers = tester.layers.whereType<BackdropFilterLayer>().toList();
    expect(layers, hasLength(2));
    for (var i = 1; i <= 30; i++) {
      repaint.value = i;
      await tester.pump();
      expect(tester.layers.whereType<BackdropFilterLayer>().toList(), layers);
    }
    repaint.value = 0;
    await tester.pumpWidget(RepaintBoundary(key: captureKey, child: scene()));
    await tester.pump();
    expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(2));
    expect(
        tester.layers
            .whereType<BackdropFilterLayer>()
            .every((layer) => layer.backdropKey == null),
        isTrue);
    expect(await pixels(), initialPixels,
        reason:
            "Repeated repaints must preserve the rendered glass appearance");
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

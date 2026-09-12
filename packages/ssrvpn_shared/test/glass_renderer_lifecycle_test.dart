import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:liquid_glass_widgets/src/renderer/internal/multi_shader_builder.dart';

const _shaderA =
    'packages/liquid_glass_widgets/shaders/liquid_glass_final_render.frag';
const _shaderB =
    'packages/liquid_glass_widgets/shaders/interactive_indicator.frag';

void main() {
  testWidgets(
      'equal shader keys reuse instances across 120 rebuilds and release on removal',
      (tester) async {
    await tester.runAsync(
        () => MultiShaderBuilder.precacheShaders([_shaderA, _shaderB]));
    ui.FragmentShader? latest;
    Widget build(String key) => Directionality(
        textDirection: TextDirection.ltr,
        child: ShaderBuilder((_, shader, child) {
          latest = shader;
          return child!;
        }, assetKey: key, child: const Text('retained')));
    await tester.pumpWidget(build(_shaderA));
    final first = latest!;
    for (var i = 0; i < 120; i++) {
      await tester.pumpWidget(build(_shaderA));
      expect(identical(latest, first), isTrue);
    }
    expect(first.debugDisposed, isFalse);
    await tester.pumpWidget(build(_shaderB));
    expect(identical(latest, first), isFalse);
    expect(first.debugDisposed, isTrue);
    final second = latest!;
    await tester.pumpWidget(const SizedBox());
    expect(second.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'capture arrival retains field state through materialization endpoints',
      (tester) async {
    await tester.runAsync(() => MultiShaderBuilder.precacheShaders([_shaderA]));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.blue, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(64, 64));
    addTearDown(image!.dispose);
    addTearDown(picture.dispose);
    var starts = 0;
    Widget build(ui.Image? capture, double progress) => MaterialApp(
        home: glass.GlassMaterializeTransition(
            animation: AlwaysStoppedAnimation(progress),
            scaleFrom: 1,
            contentSigma: 0,
            child: glass.LiquidGlassLayer(
                captureOnly: true,
                captureImage: capture,
                child: glass.GlassContainer(
                    quality: glass.GlassQuality.premium,
                    child: _StatefulField(onStart: () => starts++)))));
    await tester.pumpWidget(build(null, 0));
    await tester.enterText(find.byType(TextField), 'pending edit');
    for (final progress in [0.1, 0.5, 1.0, 0.8, 0.0, 1.0]) {
      await tester.pumpWidget(build(image, progress));
      expect(find.text('pending edit'), findsOneWidget);
      expect(starts, 1);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}

class _StatefulField extends StatefulWidget {
  const _StatefulField({required this.onStart});
  final VoidCallback onStart;
  @override
  State<_StatefulField> createState() => _StatefulFieldState();
}

class _StatefulFieldState extends State<_StatefulField> {
  @override
  void initState() {
    super.initState();
    widget.onStart();
  }

  @override
  Widget build(BuildContext context) => const Material(child: TextField());
}

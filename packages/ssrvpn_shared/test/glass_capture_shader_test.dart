import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capture shader never stretches edge texels outside glass geometry',
      () async {
    final program = await ui.FragmentProgram.fromAsset(
        'packages/liquid_glass_widgets/shaders/liquid_glass_final_render.frag');
    final shader = program.fragmentShader();
    Future<ui.Image> solid(ui.Color color) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 64, 64), ui.Paint()..color = color);
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      picture.dispose();
      return image;
    }

    final background = await solid(const ui.Color(0xff204080));
    // An opaque edge deliberately reproduces the old clamp-to-edge streak.
    final geometry = await solid(const ui.Color(0xff8080ff));
    final uniforms = List<double>.filled(34, 0);
    uniforms[0] = uniforms[1] = 64;
    uniforms[2] = uniforms[3] = 16;
    uniforms[4] = uniforms[5] = 32;
    uniforms[10] = 1.3;
    uniforms[12] = 8;
    uniforms[13] = uniforms[15] = uniforms[16] = 1;
    uniforms[30] = 1;
    for (var i = 0; i < uniforms.length; i++) {
      shader.setFloat(i, uniforms[i]);
    }
    shader.setImageSampler(0, background);
    shader.setImageSampler(1, geometry);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 64, 64), ui.Paint()..shader = shader);
    final picture = recorder.endRecording();
    final output = await picture.toImage(64, 64);
    final pixels =
        (await output.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int alpha(int x, int y) => pixels.getUint8((y * 64 + x) * 4 + 3);
    expect(alpha(32, 32), greaterThan(0));
    for (final point in [(8, 32), (56, 32), (32, 8), (32, 56)]) {
      expect(alpha(point.$1, point.$2), 0);
    }
    output.dispose();
    picture.dispose();
    shader.dispose();
    geometry.dispose();
    background.dispose();
  });
}

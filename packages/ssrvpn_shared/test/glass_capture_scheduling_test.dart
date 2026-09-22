import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/widgets/ssrvpn_drifting_background.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_capture.dart';

class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  int capturesQueued = 0;

  @override
  void addPostFrameCallback(FrameCallback callback,
      {String debugLabel = 'callback'}) {
    if (debugLabel == 'SSRVPN glass capture') capturesQueued++;
    super.addPostFrameCallback(callback, debugLabel: debugLabel);
  }
}

void main() {
  final binding = _CaptureBinding();

  testWidgets('disabled capture queues no work and resumes with fresh pixels',
      (tester) async {
    final color = ValueNotifier<Color>(Colors.blue);
    addTearDown(color.dispose);
    SsrvpnGlassFrame? frame;
    Widget page({bool highContrast = true}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(highContrast: highContrast),
            child: glass.LiquidGlassScope(
              child: SsrvpnGlassCapture(
                captureSupported: true,
                child: Stack(fit: StackFit.expand, children: [
                  SsrvpnGlassBackgroundSource(
                    child: ValueListenableBuilder<Color>(
                      valueListenable: color,
                      builder: (_, value, __) => ColoredBox(color: value),
                    ),
                  ),
                  Builder(builder: (context) {
                    return ValueListenableBuilder<SsrvpnGlassFrame?>(
                      valueListenable: SsrvpnGlassFrame.listenableOf(context)!,
                      builder: (_, value, __) {
                        frame = value;
                        return const SizedBox();
                      },
                    );
                  }),
                ]),
              ),
            ),
          ),
        );

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(page());
    for (var i = 0; i < 10; i++) {
      color.value = i.isEven ? Colors.red : Colors.blue;
      await tester.pump();
    }
    expect(binding.capturesQueued, 0);
    expect(frame, isNull);

    await tester.pumpWidget(page(highContrast: false));
    await tester.pump();
    expect(frame, isNotNull);
    final first = frame!.image;
    final count = binding.capturesQueued;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    color.value = Colors.green;
    await tester.pump();
    expect(binding.capturesQueued, count);
    expect(frame!.image, same(first));

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(binding.capturesQueued, greaterThan(count));
    expect(frame!.image, isNot(same(first)));
    final pixels = await tester.runAsync(() => frame!.image.toByteData());
    expect(pixels!.getUint8(1), (Colors.green.toARGB32() >> 8) & 0xff);
    final resumed = frame!.image;
    await tester.pumpWidget(page());
    expect(resumed.debugDisposed, isFalse);
    await tester.pump();
    expect(frame, isNull);
    expect(resumed.debugDisposed, isTrue);
    final disabledCount = binding.capturesQueued;
    color.value = Colors.red;
    await tester.pump();
    expect(binding.capturesQueued, disabledCount);
    await tester.pumpWidget(page(highContrast: false));
    await tester.pump();
    expect(frame, isNotNull);
    expect(frame!.image.debugDisposed, isFalse);
    final restoredPixels =
        await tester.runAsync(() => frame!.image.toByteData());
    expect(restoredPixels!.getUint8(0), (Colors.red.toARGB32() >> 16) & 0xff);
    await tester.pumpWidget(const SizedBox());
    expect(first.debugDisposed, isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
  });

  testWidgets('a minimized window (hidden) stops glass rasterization',
      (tester) async {
    // `hidden` is the engine's report for a minimized desktop window. The
    // capture gate must treat it like `paused`/`detached` — a window the user
    // cannot see must not keep rasterizing a fresh texture.
    final color = ValueNotifier<Color>(Colors.blue);
    addTearDown(color.dispose);
    SsrvpnGlassFrame? frame;
    Widget page() => MaterialApp(
          home: glass.LiquidGlassScope(
            child: SsrvpnGlassCapture(
              captureSupported: true,
              child: Stack(fit: StackFit.expand, children: [
                SsrvpnGlassBackgroundSource(
                  child: ValueListenableBuilder<Color>(
                    valueListenable: color,
                    builder: (_, value, __) => ColoredBox(color: value),
                  ),
                ),
                Builder(
                    builder: (context) =>
                        ValueListenableBuilder<SsrvpnGlassFrame?>(
                          valueListenable: SsrvpnGlassFrame.listenableOf(context)!,
                          builder: (_, value, __) {
                            frame = value;
                            return const SizedBox();
                          },
                        )),
              ]),
            ),
          ),
        );

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(page());
    await tester.pump();
    expect(frame, isNotNull);
    final first = frame!.image;
    final count = binding.capturesQueued;

    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    color.value = Colors.green;
    await tester.pump();
    await tester.pump();
    expect(binding.capturesQueued, count,
        reason: 'minimized window must not rasterize a new texture');
    expect(frame!.image, same(first));

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(binding.capturesQueued, greaterThan(count));

    await tester.pumpWidget(const SizedBox());
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
  });

  testWidgets(
      'drifting wallpaper rasterizes far below the wallpaper paint rate',
      (tester) async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final images = <ui.Image>{};
    await tester.pumpWidget(MaterialApp(
      home: glass.LiquidGlassScope(
        child: SsrvpnGlassCapture(
          captureSupported: true,
          child: Stack(fit: StackFit.expand, children: [
            // Motion stays enabled, so the source repaints on every frame the
            // way the production drifting wallpaper does.
            SsrvpnGlassBackgroundSource(
                child: SsrvpnDriftingBackground(
                    drift: true, child: const ColoredBox(color: Colors.blue))),
            Builder(
                builder: (context) => ValueListenableBuilder<SsrvpnGlassFrame?>(
                      valueListenable: SsrvpnGlassFrame.listenableOf(context)!,
                      builder: (_, frame, __) {
                        if (frame != null) images.add(frame.image);
                        return const SizedBox();
                      },
                    )),
          ]),
        ),
      ),
    ));
    await tester.pump();

    // 30 repaints of 16ms = 480ms. Without the throttle this rasterizes once
    // per repaint; the 100ms window caps it at ~5 full-surface captures.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(images.length, greaterThanOrEqualTo(2),
        reason: 'drift must still refresh the texture');
    expect(images.length, lessThanOrEqualTo(6),
        reason: 'throttle must keep captures well below the paint rate');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(images.every((image) => image.debugDisposed), isTrue);
  });

  testWidgets('a resized window never keeps sampling the previous texture',
      (tester) async {
    // The texture is reused across frames to save rasterization, but a resize
    // leaves it at its previous size. Sampling it would hand the glass a
    // background short by the resize delta until the throttle window closes,
    // so a size change has to bypass the throttle.
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.reset);

    SsrvpnGlassFrame? frame;
    await tester.pumpWidget(MaterialApp(
      home: glass.LiquidGlassScope(
        child: SsrvpnGlassCapture(
          captureSupported: true,
          child: Stack(fit: StackFit.expand, children: [
            const SsrvpnGlassBackgroundSource(
                child: SsrvpnDriftingBackground(
                    drift: true, child: ColoredBox(color: Colors.blue))),
            Builder(
                builder: (context) => ValueListenableBuilder<SsrvpnGlassFrame?>(
                      valueListenable: SsrvpnGlassFrame.listenableOf(context)!,
                      builder: (_, value, __) {
                        frame = value;
                        return const SizedBox();
                      },
                    )),
          ]),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(frame, isNotNull);
    expect(frame!.image.width, 1200);

    // Grow the window by 300 device pixels, then advance only 32ms: still
    // inside the 100ms raster window, yet the texture must already match.
    tester.view.physicalSize = const Size(1500, 2400);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(frame!.image.width, 1500);

    await tester.pumpWidget(const SizedBox());
  });
}

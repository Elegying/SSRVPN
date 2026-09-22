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

  testWidgets(
      'a still wallpaper that changes inside the throttle window is re-rastered',
      (tester) async {
    // Cold start: the first capture rasters the wallpaper before its image has
    // decoded (a placeholder), setting _lastRasterFrame. The image then
    // decodes within the 100ms throttle window and repaints exactly once — a
    // still wallpaper (drift:false) never repaints again. Without a trailing
    // refresh the glass would hold the placeholder (black) forever.
    final color = ValueNotifier<Color>(Colors.black);
    addTearDown(color.dispose);
    SsrvpnGlassFrame? frame;
    await tester.pumpWidget(MaterialApp(
      home: glass.LiquidGlassScope(
        child: SsrvpnGlassCapture(
          captureSupported: true,
          child: Stack(fit: StackFit.expand, children: [
            SsrvpnGlassBackgroundSource(
              child: SsrvpnDriftingBackground(
                drift: false,
                child: ValueListenableBuilder<Color>(
                  valueListenable: color,
                  builder: (_, value, __) => ColoredBox(color: value),
                ),
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
    ));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(frame, isNotNull);
    final first = frame!.image;
    final count = binding.capturesQueued;

    // The image "decodes" within the throttle window: content changes once.
    color.value = Colors.green;
    await tester.pump(const Duration(milliseconds: 16));
    // Still inside the 100ms throttle window — the change must not be dropped.
    expect(binding.capturesQueued, greaterThan(count),
        reason: 'content change inside the window must arm a deferred refresh');

    // Advance past the throttle window: the deferred refresh fires and rasters
    // the real content.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    final latest = frame!.image;
    expect(latest, isNot(same(first)),
        reason: 'the still wallpaper must refresh to the decoded pixels, not '
            'hold the placeholder forever');

    await tester.pumpWidget(const SizedBox());
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
  });
}

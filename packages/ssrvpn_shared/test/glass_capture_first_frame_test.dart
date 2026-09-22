import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_capture.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_drifting_background.dart';

void main() {
  testWidgets(
      'first capture succeeds with no lifecycle transition (state stays null)',
      (tester) async {
    // Cold start on Android: the engine's lifecycle is already `resumed` (or
    // still null) when the widget mounts, because native reported it during
    // the async shader warm-up before runApp. There is NO subsequent lifecycle
    // transition to trigger a re-capture, and a still wallpaper paints exactly
    // once. The very first capture must succeed on its own.
    SsrvpnGlassFrame? frame;
    await tester.pumpWidget(MaterialApp(
      home: glass.LiquidGlassScope(
        child: SsrvpnGlassCapture(
          captureSupported: true,
          child: Stack(fit: StackFit.expand, children: [
            SsrvpnGlassBackgroundSource(
                child: SsrvpnDriftingBackground(
                    drift: false, child: const ColoredBox(color: Colors.blue))),
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
    // No lifecycle call at all: the binding's lifecycleState is still null.
    expect(tester.binding.lifecycleState, isNull);
    await tester.pump();
    expect(frame, isNotNull,
        reason: 'first capture must succeed without any lifecycle transition');
    // And it must stay captured — no manual toggle required.
    await tester.pump(const Duration(seconds: 2));
    expect(frame, isNotNull);
  });
}

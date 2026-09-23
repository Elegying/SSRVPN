import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_capture.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_drifting_background.dart';

void main() {
  testWidgets('cold start with a still wallpaper still captures the backdrop',
      (tester) async {
    // Reproduce the cold-start sequence: the engine defaults to `detached`,
    // then reports `resumed` once the activity is foregrounded. The capture
    // gate must not get stuck requiring a manual quality toggle to recover.
    SsrvpnGlassFrame? frame;
    await tester.pumpWidget(MaterialApp(
      home: glass.LiquidGlassScope(
        child: SsrvpnGlassCapture(
          captureSupported: true,
          child: Stack(fit: StackFit.expand, children: [
            // A still wallpaper (drift: false) paints once and never repaints.
            SsrvpnGlassBackgroundSource(
                child: SsrvpnDriftingBackground(
                    drift: false, child: const ColoredBox(color: Colors.blue))),
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
    // Simulate the native resume arriving after the first frame.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(frame, isNotNull,
        reason: 'resumed after cold start must capture the backdrop without '
            'a manual quality toggle');
  });
}

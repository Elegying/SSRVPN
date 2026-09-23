import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_capture.dart';

void main() {
  testWidgets(
      'the trailing refresh wakes an idle frame and captures the latest pixels',
      (tester) async {
    final color = ValueNotifier<Color>(Colors.blue);
    addTearDown(color.dispose);
    SsrvpnGlassFrame? frame;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(
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
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    // Establish a timestamp after startup has settled. Calling resumed here
    // would reset the throttle and stop exercising the bug.
    color.value = Colors.red;
    await tester.pump();
    await tester.pump();
    final first = frame!.image;
    expect(tester.binding.hasScheduledFrame, isFalse);

    color.value = Colors.yellow;
    await tester.pump(const Duration(milliseconds: 16));
    color.value = Colors.green;
    await tester.pump(const Duration(milliseconds: 16));
    expect(frame!.image, same(first), reason: 'both changes must be throttled');
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'only the trailing timer can wake this idle page');

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(frame!.image, isNot(same(first)));
    final pixels = await tester.runAsync(() => frame!.image.toByteData());
    expect(pixels!.getUint8(0), (Colors.green.toARGB32() >> 16) & 0xff);
    expect(pixels.getUint8(1), (Colors.green.toARGB32() >> 8) & 0xff);
    expect(first.debugDisposed, isTrue);
    final latest = frame!.image;
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(frame!.image, same(latest));
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'a trailing refresh must not start an idle loop');
    await tester.pumpWidget(const SizedBox());
    expect(latest.debugDisposed, isTrue);
  });
}

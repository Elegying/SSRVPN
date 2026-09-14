import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
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
}

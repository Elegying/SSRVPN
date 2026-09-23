import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_capture.dart';

class _Scene {
  final color = ValueNotifier<Color>(Colors.blue);
  final showSource = ValueNotifier<bool>(true);
  SsrvpnGlassFrame? frame;

  Widget page({bool highContrast = false, bool tickersEnabled = true}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(highContrast: highContrast),
          child: TickerMode(
            enabled: tickersEnabled,
            child: glass.LiquidGlassScope(
              child: SsrvpnGlassCapture(
                captureSupported: true,
                child: Stack(fit: StackFit.expand, children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: showSource,
                    builder: (_, visible, __) => visible
                        ? SsrvpnGlassBackgroundSource(
                            child: ValueListenableBuilder<Color>(
                              valueListenable: color,
                              builder: (_, value, __) =>
                                  ColoredBox(color: value),
                            ),
                          )
                        : const SizedBox(),
                  ),
                  Builder(
                    builder: (context) =>
                        ValueListenableBuilder<SsrvpnGlassFrame?>(
                      valueListenable: SsrvpnGlassFrame.listenableOf(context)!,
                      builder: (_, value, __) {
                        frame = value;
                        return const SizedBox();
                      },
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );

  Future<void> primeThrottle(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    color.value = Colors.red;
    await tester.pump();
    await tester.pump();
    final last = frame!.image;
    color.value = Colors.green;
    await tester.pump(const Duration(milliseconds: 16));
    expect(frame!.image, same(last));
    expect(tester.binding.hasScheduledFrame, isFalse);
  }

  void dispose() {
    color.dispose();
    showSource.dispose();
  }
}

void main() {
  for (final lifecycle in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('a deferred refresh cannot rasterize while $lifecycle',
        (tester) async {
      final scene = _Scene();
      addTearDown(scene.dispose);
      await scene.primeThrottle(tester);
      final before = scene.frame!.image;
      tester.binding.handleAppLifecycleStateChanged(lifecycle);
      await tester.pump(const Duration(milliseconds: 120));
      expect(scene.frame!.image, same(before));
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(scene.frame!.image, isNot(same(before)));
      final pixels =
          await tester.runAsync(() => scene.frame!.image.toByteData());
      expect(pixels!.getUint8(1), (Colors.green.toARGB32() >> 8) & 0xff);
      expect(before.debugDisposed, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final disableTickers in [false, true]) {
    testWidgets(
        'a pending refresh respects disabled capture (tickers=$disableTickers)',
        (tester) async {
      final scene = _Scene();
      addTearDown(scene.dispose);
      await scene.primeThrottle(tester);
      final before = scene.frame!.image;
      await tester.pumpWidget(scene.page(
        highContrast: !disableTickers,
        tickersEnabled: !disableTickers,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(scene.frame, isNull);
      expect(before.debugDisposed, isTrue);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(scene.page());
      await tester.pump();
      expect(scene.frame, isNotNull);
      expect(scene.frame!.image.debugDisposed, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('disposing with a deferred refresh leaves no timer or frame loop',
      (tester) async {
    final scene = _Scene();
    addTearDown(scene.dispose);
    await scene.primeThrottle(tester);
    final before = scene.frame!.image;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(before.debugDisposed, isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup retries stop, and a late source can still recover',
      (tester) async {
    final scene = _Scene()..showSource.value = false;
    addTearDown(scene.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(scene.page());
    final retries =
        await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(retries, greaterThan(1),
        reason: 'retry must request an actual frame');
    expect(retries, lessThan(12),
        reason: 'an absent source must not spin forever');
    expect(scene.frame, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    scene.showSource.value = true;
    await tester.pump();
    await tester.pump();
    expect(scene.frame, isNotNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}

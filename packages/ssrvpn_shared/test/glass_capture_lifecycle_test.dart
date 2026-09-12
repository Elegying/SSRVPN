import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_capture.dart';

void main() {
  testWidgets(
      'static glass reuses full resolution texture while foreground changes',
      (tester) async {
    final wallpaper = ValueNotifier<Color>(Colors.blue);
    final foreground = ValueNotifier<int>(0);
    addTearDown(wallpaper.dispose);
    addTearDown(foreground.dispose);
    SsrvpnGlassFrame? frame;
    var frameUpdates = 0;
    final page = glass.LiquidGlassScope(
        child: SsrvpnGlassCapture(
      captureSupported: true,
      child: Stack(fit: StackFit.expand, children: [
        SsrvpnGlassBackgroundSource(
            child: ValueListenableBuilder<Color>(
          valueListenable: wallpaper,
          builder: (_, color, __) => ColoredBox(color: color),
        )),
        Builder(
            builder: (context) => ValueListenableBuilder<SsrvpnGlassFrame?>(
                  valueListenable: SsrvpnGlassFrame.listenableOf(context)!,
                  child: ValueListenableBuilder<int>(
                      valueListenable: foreground,
                      builder: (_, value, __) => Text('$value')),
                  builder: (_, value, child) {
                    frame = value;
                    frameUpdates++;
                    return child!;
                  },
                )),
      ]),
    ));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pump();
    expect(frame, isNotNull);
    final first = frame!.image;
    expect(first.width, tester.view.physicalSize.width);
    expect(first.height, tester.view.physicalSize.height);
    final initialUpdates = frameUpdates;
    for (var i = 1; i <= 120; i++) {
      foreground.value = i;
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(identical(frame!.image, first), isTrue);
    expect(frameUpdates, initialUpdates);
    expect(tester.binding.transientCallbackCount, 0);

    wallpaper.value = Colors.red;
    await tester.pump();
    await tester.pump();
    expect(identical(frame!.image, first), isFalse);
    expect(first.debugDisposed, isTrue);
    final latest = frame!.image;
    await tester.pumpWidget(const SizedBox());
    expect(latest.debugDisposed, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'route movement reuses texture, resizing replaces it, pause and dispose are safe',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final images = <ui.Image>{};
    final origins = <Offset>{};
    final pageSize = ValueNotifier<Size>(const Size(240, 360));
    addTearDown(pageSize.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()));
    final route = PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, __, ___) => Center(
          child: ValueListenableBuilder<Size>(
        valueListenable: pageSize,
        builder: (_, size, __) => SizedBox.fromSize(
          size: size,
          child: glass.LiquidGlassScope(
              child: SsrvpnGlassCapture(
            captureSupported: true,
            child: Stack(fit: StackFit.expand, children: [
              const SsrvpnGlassBackgroundSource(
                  child: ColoredBox(color: Colors.blue)),
              Builder(
                  builder: (context) =>
                      ValueListenableBuilder<SsrvpnGlassFrame?>(
                        valueListenable:
                            SsrvpnGlassFrame.listenableOf(context)!,
                        builder: (_, frame, __) {
                          if (frame != null) {
                            images.add(frame.image);
                            origins.add(frame.origin);
                          }
                          return const Text('page');
                        },
                      )),
            ]),
          )),
        ),
      )),
      transitionsBuilder: (_, animation, __, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(animation),
          child: child),
    );
    navigator.currentState!.push(route);
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(images.length, 1);
    expect(origins.length, greaterThan(5));
    pageSize.value = const Size(360, 240);
    await tester.pump();
    await tester.pump();
    expect(images.length, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pageSize.value = const Size(480, 240);
    await tester.pump();
    await tester.pump();
    expect(images.length, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(images.length, 3);
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(images.every((image) => image.debugDisposed), isTrue);
    expect(tester.takeException(), isNull);
  });
}

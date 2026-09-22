import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_connection_halo.dart';

void main() {
  testWidgets('connected halo expands locally without rebuilding the button',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var builds = 0;
    final child = Builder(builder: (_) {
      builds++;
      return const SizedBox.square(dimension: 200);
    });
    Widget scene(
            {bool enabled = true, bool reduce = false, bool active = true}) =>
        MaterialApp(
            home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Center(
              child: TickerMode(
            enabled: active,
            child: SsrvpnConnectionHalo(
              enabled: enabled,
              size: 200,
              color: Colors.green,
              child: child,
            ),
          )),
        ));
    await tester.pumpWidget(scene());
    final initialBuilds = builds;
    final halo = find.byKey(const Key('ssrvpn-connected-halo'));
    expect(tester.getSize(halo), const Size(252, 252));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(builds, initialBuilds);
    final painter = tester.widget<CustomPaint>(halo).painter!;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(252, 252));
      final picture = recorder.endRecording();
      final image = await picture.toImage(252, 252);
      final pixels =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int alpha(int x, int y) => pixels.getUint8((y * 252 + x) * 4 + 3);
      expect(alpha(126, 126), 0); // No full-disc fill.
      expect(alpha(230, 126), greaterThan(10)); // Soft ring outside the button.
      expect(alpha(251, 126), 0); // Bounded halo, not a full-screen effect.
      image.dispose();
      picture.dispose();
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    // A focus change is not a hidden window: the pulse must survive it instead
    // of stalling mid-cycle and jumping when focus returns.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    for (final page in [
      scene(reduce: true),
      scene(active: false),
      scene(enabled: false)
    ]) {
      await tester.pumpWidget(page);
      await tester.pump();
      expect(halo, findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    }
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unreported lifecycle state keeps the halo still',
      (tester) async {
    // A host that never reports lifecycle leaves `lifecycleState == null`. The
    // halo must not guess "active": it repeats forever, so treating a missing
    // state as active would spin the animation on a host that never reports
    // anything. It only starts once a first definite `resumed` arrives.
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: MediaQueryData(disableAnimations: false),
      child: Center(
          child: SsrvpnConnectionHalo(
        enabled: true,
        size: 200,
        color: Colors.green,
        child: const SizedBox.square(dimension: 200),
      )),
    )));
    final halo = find.byKey(const Key('ssrvpn-connected-halo'));
    expect(halo, findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'no lifecycle report yet — the halo must stay still');
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'a first definite resumed starts the pulse');

    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(tester.takeException(), isNull);
  });
}

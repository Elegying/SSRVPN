import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:ssrvpn_shared/widgets/ssrvpn_drifting_background.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_capture.dart';

/// Regression guard for first-open on Windows.
///
/// The runner's WndProc handles `WM_ACTIVATE` without telling Flutter, so a
/// freshly launched window can sit in `inactive` (or with no reported state)
/// while it is plainly visible. Both decorative layers used to read that as
/// "the window is hidden": the wallpaper froze and the glass never received a
/// texture, until some unrelated event delivered `resumed`. These tests mount
/// in exactly that state and require both layers to come up working.
void main() {
  Widget page({
    required void Function(Object?) onFrame,
  }) =>
      glass.LiquidGlassScope(
          child: SsrvpnGlassCapture(
        captureSupported: true,
        child: Stack(fit: StackFit.expand, children: [
          SsrvpnGlassBackgroundSource(
              child: SsrvpnDriftingBackground(
                  drift: true, child: const ColoredBox(color: Colors.blue))),
          Builder(
              builder: (context) => ValueListenableBuilder<Object?>(
                    valueListenable: SsrvpnGlassFrame.listenableOf(context)!,
                    builder: (_, value, __) {
                      onFrame(value);
                      return const SizedBox();
                    },
                  )),
        ]),
      ));

  testWidgets('a window mounted while inactive still installs a glass texture',
      (tester) async {
    Object? frame;
    var updates = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(),
            child: page(onFrame: (v) {
              frame = v;
              updates++;
            }))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(frame, isNotNull,
        reason: 'an unfocused but visible window must still get a texture');
    expect(updates, greaterThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(frame, isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a window mounted while inactive still drifts its wallpaper',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(),
            child: glass.LiquidGlassScope(
                child: SsrvpnGlassCapture(
              captureSupported: true,
              child: SsrvpnGlassBackgroundSource(
                  child: SsrvpnDriftingBackground(
                      drift: true,
                      child: const ColoredBox(
                          key: Key('wp'), color: Colors.blue))),
            )))));
    Offset pos() => tester
        .widget<FractionalTranslation>(find.descendant(
            of: find.byType(SsrvpnDriftingBackground),
            matching: find.byType(FractionalTranslation)))
        .translation;
    final initial = pos();
    await tester.pump(const Duration(seconds: 5));
    expect(pos(), isNot(initial),
        reason: 'the wallpaper must move for an opted-in, visible window');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_info_dialog.dart';

/// Exercise the real dialog over two maximally different foreground pages.
Future<void> expectRuleDialogOccludesPage(
    WidgetTester tester, GlobalKey captureKey) async {
  final panel = find.byType(SsrvpnModalGlassPanel);
  final rect = tester.getRect(panel);
  final context = tester.element(panel);
  final route = ModalRoute.of(context)!;
  final color = ValueNotifier<Color>(Colors.black);
  final backdrop = OverlayEntry(
      builder: (_) => ValueListenableBuilder<Color>(
          valueListenable: color,
          builder: (_, value, __) => ColoredBox(color: value)));
  Navigator.of(context)
      .overlay!
      .insert(backdrop, below: route.overlayEntries.first);
  try {
    Future<List<int>> sample() async {
      await tester.pumpAndSettle();
      final boundary = captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final points = [
            const Offset(4, 4),
            for (final fraction in [.25, .5, .75])
              boundary.globalToLocal(
                  Offset(rect.left + 12, rect.top + rect.height * fraction)),
          ];
          return [
            for (final point in points)
              for (var channel = 0; channel < 3; channel++)
                bytes.getUint8(
                    (point.dy.floor() * image.width + point.dx.floor()) * 4 +
                        channel),
          ];
        } finally {
          image.dispose();
        }
      }))!;
    }

    final black = await sample();
    color.value = Colors.white;
    final white = await sample();
    expect((black.first - white.first).abs(), greaterThan(80),
        reason: 'The page below the modal must really change.');
    expect(black.skip(3), white.skip(3),
        reason: 'Underlying page pixels must not show through the rule form.');
  } finally {
    backdrop.remove();
    backdrop.dispose();
    await tester.pumpAndSettle();
    color.dispose();
  }
}

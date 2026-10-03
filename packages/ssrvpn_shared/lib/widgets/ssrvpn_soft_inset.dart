import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Clipped inner shadows keep the recess inside its hit target.
class SsrvpnSoftInset extends StatelessWidget {
  const SsrvpnSoftInset({super.key, required this.child, this.radius = 22});
  final Widget child;
  final double radius;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _InsetPainter(radius), child: child);
}

class _InsetPainter extends CustomPainter {
  const _InsetPainter(this.radius);
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(bounds, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(shape);
    for (final layer in const [
      (Offset(5, 6), Color(0x99818D9E)),
      (Offset(-5, -5), Color(0xFFFFFFFF)),
    ]) {
      final mask = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(bounds.inflate(30))
        ..addRRect(shape.shift(layer.$1));
      canvas.drawPath(
          mask,
          Paint()
            ..color = layer.$2
            ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InsetPainter oldDelegate) => radius != oldDelegate.radius;
}

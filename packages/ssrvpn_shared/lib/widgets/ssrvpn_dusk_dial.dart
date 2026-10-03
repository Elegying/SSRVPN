import 'package:flutter/material.dart';

/// The base ring and animated ripples share the exact widget center.
class SsrvpnDuskDial extends StatelessWidget {
  const SsrvpnDuskDial({super.key});
  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _DuskDialPainter());
}

class _DuskDialPainter extends CustomPainter {
  const _DuskDialPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide;
    final center = size.center(Offset.zero);
    final radius = unit * .37;
    for (final layer in const [(0.045, 0.24), (0.018, 0.5)]) {
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = unit * .018
            ..color = const Color(0xFFFFC698).withValues(alpha: layer.$2)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, unit * layer.$1));
    }
    canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = unit * .011
          ..color = const Color(0xFFFFF1CF));
  }

  @override
  bool shouldRepaint(_DuskDialPainter oldDelegate) => false;
}

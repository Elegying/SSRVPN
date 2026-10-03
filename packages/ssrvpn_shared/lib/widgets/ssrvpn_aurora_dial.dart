import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Front-facing geometry keeps every ring and the live power glyph concentric.
class SsrvpnAuroraDial extends StatelessWidget {
  const SsrvpnAuroraDial({super.key, this.rotation = 0});
  final double rotation;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _DialPainter(rotation));
}

class _DialPainter extends CustomPainter {
  const _DialPainter(this.rotation);
  final double rotation;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final unit = size.shortestSide;
    void ring(double radius, double width, Color color, {double blur = 0}) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * width
        ..color = color;
      if (blur > 0) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, unit * blur);
      }
      canvas.drawCircle(center, unit * radius, paint);
    }

    ring(.46, .016, const Color(0x663AE6FF), blur: .035);
    canvas.drawCircle(
        center, unit * .465, Paint()..color = const Color(0xFF061421));
    ring(.477, .003, const Color(0xFF174861));
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    canvas.translate(-center.dx, -center.dy);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = unit * .013
      ..shader = const SweepGradient(colors: [
        Color(0xFF5D5BFF),
        Color(0xFF33DDFC),
        Color(0xFF29F0D5),
        Color(0xFF33DDFC),
        Color(0xFF5D5BFF)
      ]).createShader(Rect.fromCircle(center: center, radius: unit * .45));
    canvas.drawCircle(center, unit * .449, rim);
    for (var i = 0; i < 64; i++) {
      final angle = i * math.pi * 2 / 64;
      final direction = Offset(math.sin(angle), -math.cos(angle));
      canvas.drawLine(
          center + direction * unit * .413,
          center + direction * unit * (i % 4 == 0 ? .427 : .422),
          Paint()
            ..color = const Color(0xFF32CBDC)
            ..strokeWidth = unit * .0035);
    }
    canvas.restore();
    final disc = Rect.fromCircle(center: center, radius: unit * .385);
    canvas.drawCircle(
        center,
        unit * .385,
        Paint()
          ..shader = const RadialGradient(
              center: Alignment(0, -.55),
              radius: 1.15,
              colors: [
                Color(0xFF154659),
                Color(0xFF071727),
                Color(0xFF040D18)
              ]).createShader(disc));
    ring(.385, .018, const Color(0x8856F6FF), blur: .018);
    ring(.385, .007, const Color(0xFF5EF1F2));
    ring(.368, .002, const Color(0xFF176170));
  }

  @override
  bool shouldRepaint(_DialPainter oldDelegate) =>
      oldDelegate.rotation != rotation;
}

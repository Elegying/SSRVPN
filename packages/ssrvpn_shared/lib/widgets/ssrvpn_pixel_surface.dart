import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Stepped silhouettes keep pixel panels recognisable at every canvas size.
/// The frame is painted around live widgets, never baked around sample data.
class SsrvpnPixelSurface extends StatelessWidget {
  const SsrvpnPixelSurface(
      {super.key,
      required this.child,
      required this.color,
      this.padding = EdgeInsets.zero,
      this.accent});
  final Widget child;
  final Color color;
  final Color? accent;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _PixelFrame(color, accent),
        child: Padding(padding: padding, child: child),
      );
}

Path _steps(Rect r, double step) => Path()
  ..moveTo(r.left + step * 3, r.top)
  ..lineTo(r.right - step * 3, r.top)
  ..lineTo(r.right - step * 3, r.top + step)
  ..lineTo(r.right - step, r.top + step)
  ..lineTo(r.right - step, r.top + step * 3)
  ..lineTo(r.right, r.top + step * 3)
  ..lineTo(r.right, r.bottom - step * 3)
  ..lineTo(r.right - step, r.bottom - step * 3)
  ..lineTo(r.right - step, r.bottom - step)
  ..lineTo(r.right - step * 3, r.bottom - step)
  ..lineTo(r.right - step * 3, r.bottom)
  ..lineTo(r.left + step * 3, r.bottom)
  ..lineTo(r.left + step * 3, r.bottom - step)
  ..lineTo(r.left + step, r.bottom - step)
  ..lineTo(r.left + step, r.bottom - step * 3)
  ..lineTo(r.left, r.bottom - step * 3)
  ..lineTo(r.left, r.top + step * 3)
  ..lineTo(r.left + step, r.top + step * 3)
  ..lineTo(r.left + step, r.top + step)
  ..lineTo(r.left + step * 3, r.top + step)
  ..close();

class _PixelFrame extends CustomPainter {
  const _PixelFrame(this.fill, this.accent);
  final Color fill;
  final Color? accent;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide < 16) return;
    final rect = Offset.zero & size;
    final step = math.min(3.0, size.height / 18);
    final paint = Paint()..isAntiAlias = false;
    canvas.drawPath(
        _steps(rect, step), paint..color = accent ?? const Color(0xFF53785A));
    canvas.drawPath(
        _steps(rect.deflate(2), step), paint..color = const Color(0xFF0C281F));
    canvas.drawPath(_steps(rect.deflate(4), step), paint..color = fill);
  }

  @override
  bool shouldRepaint(_PixelFrame old) =>
      fill != old.fill || accent != old.accent;
}

class SsrvpnPixelStatus extends StatelessWidget {
  const SsrvpnPixelStatus(
      {super.key, required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      child: SsrvpnPixelSurface(
          color: const Color(0xFF163D2D),
          accent: color,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.auto_awesome, size: 12, color: color),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    color: color)),
            const SizedBox(width: 12),
            Icon(Icons.auto_awesome, size: 12, color: color),
          ])));
}

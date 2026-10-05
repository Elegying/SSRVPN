import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import 'ssrvpn_theme.dart';
import 'ssrvpn_pixel_surface.dart';

/// Theme materials apply to real controls, so routes and dialogs retain their
/// interaction, focus, text and clipping rather than becoming a screenshot.
class SsrvpnIllustratedSurface extends StatelessWidget {
  const SsrvpnIllustratedSurface(
      {super.key,
      required this.child,
      this.radius = 18,
      this.padding = EdgeInsets.zero,
      this.tint,
      this.borderColor,
      this.circular = false});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? tint, borderColor;
  final bool circular;
  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    final pixel = theme.variant == AppThemeVariant.pixel;
    final effectiveRadius = pixel ? 5.0 : radius;
    final base =
        tint == null ? theme.surface : Color.alphaBlend(tint!, theme.surface);
    if (pixel && !circular) {
      return SsrvpnPixelSurface(
          color: base,
          accent: borderColor,
          padding: padding.add(const EdgeInsets.all(3)),
          child: child);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : BorderRadius.circular(effectiveRadius),
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(Colors.white.withValues(alpha: .16), base),
              base
            ]),
        border: Border.all(
            color:
                borderColor ?? (pixel ? const Color(0xFF64866C) : theme.border),
            width: pixel ? 2 : 1.2),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: pixel ? .28 : .12),
              offset: Offset(pixel ? 3 : 0, pixel ? 3 : 3),
              blurRadius: pixel ? 0 : 6)
        ],
      ),
      child: CustomPaint(
          foregroundPainter: circular
              ? null
              : _MaterialTrim(
                  variant: theme.variant,
                  radius: effectiveRadius,
                  color: theme.textSecondary),
          child: Padding(padding: padding, child: child)),
    );
  }
}

class _MaterialTrim extends CustomPainter {
  const _MaterialTrim(
      {required this.variant, required this.radius, required this.color});
  final AppThemeVariant variant;
  final double radius;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 20 || size.height < 20) return;
    final rect = (Offset.zero & size).deflate(4);
    final paint = Paint()
      ..color = color.withValues(alpha: .35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    if (variant == AppThemeVariant.journal) {
      final path = Path()
        ..addRRect(RRect.fromRectAndRadius(
            rect, Radius.circular(math.max(0, radius - 4))));
      for (final metric in path.computeMetrics()) {
        for (var d = 0.0; d < metric.length; d += 6) {
          canvas.drawPath(
              metric.extractPath(d, math.min(d + 3, metric.length)), paint);
        }
      }
    } else if (variant == AppThemeVariant.orbital) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              rect, Radius.circular(math.max(0, radius - 4))),
          paint);
      if (size.height >= 70) {
        for (final p in [
          rect.topLeft + const Offset(4, 4),
          rect.topRight + const Offset(-4, 4),
          rect.bottomLeft + const Offset(4, -4),
          rect.bottomRight + const Offset(-4, -4)
        ]) {
          canvas.drawCircle(p, 2, paint);
          canvas.drawLine(
              p - const Offset(1, 1), p + const Offset(1, 1), paint);
        }
      }
    } else if (variant == AppThemeVariant.pixel) {
      canvas.drawRect(rect, paint..strokeWidth = 2);
    } else {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              rect, Radius.circular(math.max(0, radius - 4))),
          paint..color = Colors.white.withValues(alpha: .6));
    }
  }

  @override
  bool shouldRepaint(_MaterialTrim old) =>
      old.variant != variant || old.radius != radius || old.color != color;
}

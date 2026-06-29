import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Premium Connection Button
class ConnectionButton extends StatefulWidget {
  final bool isConnected;
  final bool isConnecting;
  final VoidCallback? onTap;

  const ConnectionButton(
      {super.key,
      required this.isConnected,
      this.isConnecting = false,
      this.onTap});

  @override
  State<ConnectionButton> createState() => _ConnectionButtonState();
}

class _ConnectionButtonState extends State<ConnectionButton>
    with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late AnimationController _ringCtrl;
  late AnimationController _breatheCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _ringCtrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 4));
    _breatheCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 3500));
    _sync();
  }

  @override
  void didUpdateWidget(covariant ConnectionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isConnected != widget.isConnected ||
        oldWidget.isConnecting != widget.isConnecting) {
      _sync();
    }
  }

  void _sync() {
    if (widget.isConnected || widget.isConnecting) {
      if (!_pulseCtrl.isAnimating) _pulseCtrl.repeat();
      if (!_ringCtrl.isAnimating) _ringCtrl.repeat();
      if (!_breatheCtrl.isAnimating) _breatheCtrl.repeat();
    } else {
      _pulseCtrl.stop();
      _ringCtrl.stop();
      _breatheCtrl.stop();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _ringCtrl.dispose();
    _breatheCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isConnecting ? null : widget.onTap,
      child: SizedBox(
        width: 140,
        height: 140,
        child: AnimatedBuilder(
          animation: Listenable.merge([_pulseCtrl, _ringCtrl, _breatheCtrl]),
          builder: (context, child) {
            return CustomPaint(
              painter: _Painter(
                connected: widget.isConnected,
                connecting: widget.isConnecting,
                pulse: _pulseCtrl.value,
                ring: _ringCtrl.value,
                breathe: _breatheCtrl.value,
              ),
              child: Center(
                child: widget.isConnecting
                    ? const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.power_settings_new_rounded,
                              color: Colors.white,
                              size: 36,
                              shadows: [
                                Shadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 12,
                                    offset: const Offset(0, 2))
                              ]),
                          const SizedBox(height: 10),
                          Text(widget.isConnected ? '断开' : '连接',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 3)),
                        ],
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Painter extends CustomPainter {
  _Painter(
      {required this.connected,
      required this.connecting,
      required this.pulse,
      required this.ring,
      required this.breathe});

  final bool connected;
  final bool connecting;
  final double pulse;
  final double ring;
  final double breathe;
  Size _size = Size.zero;

  @override
  void paint(Canvas canvas, Size size) {
    _size = size;
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;
    if (connected || connecting) _drawPulse(canvas, c, r);
    _drawCore(canvas, c, r);
    if (connected) _drawRing(canvas, c, r);
    _drawHighlight(canvas, c, r);
  }

  void _drawPulse(Canvas canvas, Offset c, double r) {
    for (int i = 0; i < 4; i++) {
      final t = (pulse + i / 4) % 1.0;
      final rr = r * (0.85 + t * 0.8);
      final a = ((1.0 - t) * (connected ? 0.45 : 0.2)).clamp(0.0, 1.0);
      canvas.drawCircle(
          c,
          rr,
          Paint()
            ..color = (connected ? AppTheme.success : AppTheme.primary)
                .withValues(alpha: a)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
    }
  }

  void _drawCore(Canvas canvas, Offset c, double r) {
    final br = r * 0.58;
    final scale = 1.0 + (connected ? 0.025 * sin(breathe * 2 * pi) : 0);
    final ar = br * scale;
    final colors = connected
        ? [AppTheme.success, AppTheme.successMuted]
        : [AppTheme.primary, AppTheme.primaryMuted];
    final rect = Rect.fromCircle(center: c, radius: ar);
    canvas.drawCircle(
        c + const Offset(0, 2),
        ar + 10,
        Paint()
          ..color = (connected ? AppTheme.success : AppTheme.primary)
              .withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28));
    canvas.drawCircle(
        c + const Offset(0, 3),
        ar,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
    canvas.drawCircle(
        c,
        ar,
        Paint()
          ..shader = LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors)
              .createShader(rect));
    canvas.drawCircle(
        c,
        ar,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
  }

  void _drawRing(Canvas canvas, Offset c, double r) {
    final rr = r * 0.68;
    const sweep = pi * 0.45;
    final start = ring * 2 * pi;
    final rect = Rect.fromCircle(center: c, radius: rr);
    canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..shader = SweepGradient(
              startAngle: start,
              endAngle: start + sweep,
              colors: [
                Colors.transparent,
                AppTheme.success.withValues(alpha: 0.7),
                Colors.transparent
              ]).createShader(rect));
    canvas.drawArc(
        rect,
        start + pi,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = SweepGradient(
              startAngle: start + pi,
              endAngle: start + pi + sweep,
              colors: [
                Colors.transparent,
                AppTheme.success.withValues(alpha: 0.35),
                Colors.transparent
              ]).createShader(rect));
  }

  void _drawHighlight(Canvas canvas, Offset c, double r) {
    final br = r * 0.58;
    final path = Path()
      ..addArc(Rect.fromCircle(center: c, radius: br), -pi * 0.85, pi * 0.85);
    canvas.save();
    canvas.clipPath(
        Path()..addRect(Rect.fromLTWH(0, 0, _size.width, _size.height / 2)));
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = br * 0.1);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _Painter old) =>
      old.connected != connected ||
      old.connecting != connecting ||
      old.pulse != pulse ||
      old.ring != ring ||
      old.breathe != breathe;
}

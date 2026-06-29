import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 连接按钮 — 高端大气设计，带动画光环
class ConnectionButton extends StatefulWidget {
  final bool isConnected;
  final bool isConnecting;
  final VoidCallback? onTap;

  const ConnectionButton({
    super.key,
    required this.isConnected,
    this.isConnecting = false,
    this.onTap,
  });

  @override
  State<ConnectionButton> createState() => _ConnectionButtonState();
}

class _ConnectionButtonState extends State<ConnectionButton>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _ringController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _syncAnimations();
  }

  @override
  void didUpdateWidget(covariant ConnectionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isConnected != widget.isConnected ||
        oldWidget.isConnecting != widget.isConnecting) {
      _syncAnimations();
    }
  }

  /// 仅在连接/连接中状态跑动画；空闲时画面是静态的，停掉避免每帧重绘耗电
  void _syncAnimations() {
    if (widget.isConnected || widget.isConnecting) {
      if (!_pulseController.isAnimating) _pulseController.repeat();
      if (!_ringController.isAnimating) _ringController.repeat();
    } else {
      _pulseController.stop();
      _ringController.stop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: widget.isConnecting ? null : widget.onTap,
      child: SizedBox(
        width: 120,
        height: 120,
        child: AnimatedBuilder(
          animation: Listenable.merge([_pulseController, _ringController]),
          builder: (context, child) {
            return CustomPaint(
              painter: _ConnectionButtonPainter(
                isConnected: widget.isConnected,
                isConnecting: widget.isConnecting,
                pulseValue: _pulseController.value,
                ringValue: _ringController.value,
                isDark: isDark,
              ),
              child: Center(
                child: widget.isConnecting
                    ? const SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.power_settings_new_rounded,
                            color: Colors.white,
                            size: 32,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(alpha: 60 / 255),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.isConnected ? '断开' : '连接',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 220 / 255),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
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

class _ConnectionButtonPainter extends CustomPainter {
  final bool isConnected;
  final bool isConnecting;
  final double pulseValue;
  final double ringValue;
  final bool isDark;
  Size _size = Size.zero;

  _ConnectionButtonPainter({
    required this.isConnected,
    required this.isConnecting,
    required this.pulseValue,
    required this.ringValue,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _size = size;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;

    // 1. 外层光环（连接时脉冲扩散）
    if (isConnected || isConnecting) {
      _drawPulseRings(canvas, center, radius);
    }

    // 2. 主按钮背景
    _drawMainButton(canvas, center, radius);

    // 3. 旋转光环
    if (isConnected) {
      _drawRotatingRing(canvas, center, radius);
    }

    // 4. 玻璃高光
    _drawGlassHighlight(canvas, center, radius);
  }

  void _drawPulseRings(Canvas canvas, Offset center, double radius) {
    for (int i = 0; i < 3; i++) {
      final t = (pulseValue + i / 3) % 1.0;
      final expandRadius = radius * (1.0 + t * 0.5);
      final alpha = ((1.0 - t) * (isConnected ? 50 : 25)).toInt();

      final color = isConnected
          ? AppTheme.successColor.withValues(alpha: (alpha) / 255)
          : AppTheme.primaryColor.withValues(alpha: (alpha) / 255);

      canvas.drawCircle(
        center,
        expandRadius,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  void _drawMainButton(Canvas canvas, Offset center, double radius) {
    final buttonRadius = radius * 0.65;

    // 主渐变
    final gradient = isConnected
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF10B981), Color(0xFF059669)],
          )
        : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
          );

    final rect = Rect.fromCircle(center: center, radius: buttonRadius);

    // 阴影
    final shadowColor = isConnected
        ? AppTheme.successColor.withValues(alpha: 80 / 255)
        : AppTheme.primaryColor.withValues(alpha: 80 / 255);
    canvas.drawCircle(
      center + const Offset(0, 4),
      buttonRadius,
      Paint()
        ..color = shadowColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
    );

    // 主圆
    canvas.drawCircle(
      center,
      buttonRadius,
      Paint()..shader = gradient.createShader(rect),
    );

    // 边框高光
    canvas.drawCircle(
      center,
      buttonRadius,
      Paint()
        ..color = Colors.white.withValues(alpha: 30 / 255)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _drawRotatingRing(Canvas canvas, Offset center, double radius) {
    final ringRadius = radius * 0.75;
    const sweepAngle = pi * 0.6;
    final startAngle = ringValue * 2 * pi;

    final rect = Rect.fromCircle(center: center, radius: ringRadius);

    canvas.drawArc(
      rect,
      startAngle,
      sweepAngle,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = SweepGradient(
          startAngle: startAngle,
          endAngle: startAngle + sweepAngle,
          colors: [
            Colors.transparent,
            AppTheme.successLight.withValues(alpha: 150 / 255),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
  }

  void _drawGlassHighlight(Canvas canvas, Offset center, double radius) {
    final buttonRadius = radius * 0.65;

    // 顶部半月形高光
    final highlightPath = Path()
      ..addArc(
        Rect.fromCircle(center: center, radius: buttonRadius),
        -pi * 0.85,
        pi * 0.85,
      );

    canvas.save();
    canvas.clipPath(
      Path()..addRect(Rect.fromLTWH(0, 0, _size.width, _size.height / 2)),
    );

    canvas.drawPath(
      highlightPath,
      Paint()
        ..color = Colors.white.withValues(alpha: (isDark ? 20 : 40) / 255)
        ..style = PaintingStyle.stroke
        ..strokeWidth = buttonRadius * 0.15,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ConnectionButtonPainter oldDelegate) {
    return oldDelegate.isConnected != isConnected ||
        oldDelegate.isConnecting != isConnecting ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.ringValue != ringValue;
  }
}

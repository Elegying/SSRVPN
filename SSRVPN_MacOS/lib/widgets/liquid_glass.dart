import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class LiquidGlassBackdrop extends StatelessWidget {
  const LiquidGlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? const [
                        Color(0xFF05070A),
                        Color(0xFF101827),
                        Color(0xFF07090D),
                      ]
                    : const [
                        Color(0xFFF8FBFF),
                        Color(0xFFE8F2FF),
                        Color(0xFFF7F9FC),
                      ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _LiquidBackdropPainter(isDark: isDark),
          ),
        ),
        child,
      ],
    );
  }
}

class LiquidGlassContainer extends StatelessWidget {
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.blur = 30,
    this.opacity = 0.12,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.width,
    this.height,
    this.borderOpacity,
    this.shadowOpacity,
    this.tint,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final double? borderOpacity;
  final double? shadowOpacity;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = opacity.clamp(0.0, 1.0).toDouble();
    final darkTint = tint ?? const Color(0xFF111C2D);
    final lightTint = tint ?? Colors.white;
    final borderAlpha = borderOpacity ?? (isDark ? 0.18 : 0.74);
    final shadowAlpha = shadowOpacity ?? (isDark ? 0.48 : 0.14);
    final darkBodyAlpha = (0.66 + fill * 0.58).clamp(0.66, 0.82).toDouble();
    final darkLiftAlpha = (0.42 + fill * 0.24).clamp(0.42, 0.56).toDouble();

    return _HoverableGlass(
      builder: (context, hovered) {
        final hoverAlpha = hovered ? 0.08 : 0.0;
        return AnimatedScale(
          scale: hovered ? 1.006 : 1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedSlide(
            offset: hovered ? const Offset(0, -0.004) : Offset.zero,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: RepaintBoundary(
              child: Container(
                width: width,
                height: height,
                margin: margin,
                child: ClipRRect(
                  borderRadius: borderRadius,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: borderRadius,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isDark
                              ? [
                                  const Color(0xFF23304A)
                                      .withValues(alpha: darkBodyAlpha),
                                  darkTint.withValues(alpha: darkBodyAlpha),
                                  const Color(0xFF07101C)
                                      .withValues(alpha: 0.78),
                                  AppTheme.primary
                                      .withValues(alpha: darkLiftAlpha * 0.22),
                                  AppTheme.accentColor
                                      .withValues(alpha: darkLiftAlpha * 0.12),
                                ]
                              : [
                                  lightTint.withValues(
                                      alpha: 0.78 + fill * 0.18),
                                  lightTint.withValues(
                                      alpha: 0.56 + fill * 0.14),
                                  AppTheme.primary
                                      .withValues(alpha: fill * 0.2),
                                  AppTheme.accentColor
                                      .withValues(alpha: fill * 0.12),
                                ],
                          stops: isDark
                              ? const [0.0, 0.34, 0.7, 0.88, 1.0]
                              : const [0.0, 0.42, 0.74, 1.0],
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(
                            alpha: (borderAlpha + hoverAlpha).clamp(0, 1),
                          ),
                          width: hovered ? 1.2 : 1.05,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: shadowAlpha),
                            blurRadius: hovered ? 48 : 42,
                            spreadRadius: -16,
                            offset: const Offset(0, 24),
                          ),
                          BoxShadow(
                            color: AppTheme.primary.withValues(
                              alpha: hovered
                                  ? (isDark ? 0.22 : 0.14)
                                  : (isDark ? 0.1 : 0.08),
                            ),
                            blurRadius: hovered ? 42 : 30,
                            spreadRadius: -18,
                            offset: const Offset(-10, -8),
                          ),
                          BoxShadow(
                            color: Colors.white.withValues(
                              alpha: isDark ? 0.035 : 0.54,
                            ),
                            blurRadius: 4,
                            offset: const Offset(0, -1),
                          ),
                        ],
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _LiquidGlassSurfacePainter(
                                  isDark: isDark,
                                  hovered: hovered,
                                ),
                              ),
                            ),
                          ),
                          Padding(padding: padding, child: child),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: borderRadius,
                                  border: Border.all(
                                    color: Colors.white.withValues(
                                      alpha: hovered
                                          ? (isDark ? 0.2 : 1)
                                          : (isDark ? 0.12 : 0.92),
                                    ),
                                    width: 0.55,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HoverableGlass extends StatefulWidget {
  const _HoverableGlass({required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_HoverableGlass> createState() => _HoverableGlassState();
}

class _HoverableGlassState extends State<_HoverableGlass> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

class LiquidGlassButton extends StatefulWidget {
  const LiquidGlassButton({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
  });

  final Widget child;
  final VoidCallback? onTap;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  State<LiquidGlassButton> createState() => _LiquidGlassButtonState();
}

class _LiquidGlassButtonState extends State<LiquidGlassButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _brightnessAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.965).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _brightnessAnim = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap?.call();
      },
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnim.value,
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix([
                _brightnessAnim.value,
                0,
                0,
                0,
                0,
                0,
                _brightnessAnim.value,
                0,
                0,
                0,
                0,
                0,
                _brightnessAnim.value,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
              ]),
              child: LiquidGlassContainer(
                blur: 24,
                opacity: 0.1,
                borderRadius:
                    BorderRadius.all(Radius.circular(widget.borderRadius)),
                padding: widget.padding,
                child: widget.child,
              ),
            ),
          );
        },
      ),
    );
  }
}

class LiquidGlassNavBar extends StatelessWidget {
  const LiquidGlassNavBar({
    super.key,
    required this.currentIndex,
    required this.items,
    required this.onTap,
  });

  final int currentIndex;
  final List<NavItem> items;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: LiquidGlassContainer(
        blur: 34,
        opacity: isDark ? 0.08 : 0.55,
        borderRadius: const BorderRadius.all(Radius.circular(32)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        shadowOpacity: isDark ? 0.28 : 0.08,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(items.length, (index) {
            final item = items[index];
            final isActive = index == currentIndex;

            return Expanded(
              child: GestureDetector(
                onTap: () => onTap(index),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppTheme.primary.withValues(
                            alpha: isDark ? 0.16 : 0.11,
                          )
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: isActive
                          ? AppTheme.primary.withValues(alpha: 0.34)
                          : Colors.transparent,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isActive ? item.activeIcon : item.icon,
                        size: 22,
                        color: isActive
                            ? AppTheme.primary
                            : (isDark ? Colors.white60 : Colors.black45),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight:
                              isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive
                              ? AppTheme.primary
                              : (isDark ? Colors.white60 : Colors.black45),
                          decoration: TextDecoration.none,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class NavItem {
  const NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class _LiquidBackdropPainter extends CustomPainter {
  const _LiquidBackdropPainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final sheenPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.018 : 0.42),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.42));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.42),
      sheenPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _LiquidBackdropPainter oldDelegate) {
    return oldDelegate.isDark != isDark;
  }
}

class _LiquidGlassSurfacePainter extends CustomPainter {
  const _LiquidGlassSurfacePainter({
    required this.isDark,
    required this.hovered,
  });

  final bool isDark;
  final bool hovered;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.shortestSide < 80 ? 14 : 28);
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.5), radius);

    final topGlow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.13 : 0.9),
          Colors.white.withValues(alpha: isDark ? 0.035 : 0.24),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.22, 0.72],
      ).createShader(rect);
    canvas.drawRRect(rrect, topGlow);

    final lowerShade = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: isDark ? 0.36 : 0.08),
        ],
        stops: const [0.42, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, lowerShade);

    if (hovered) {
      final hoverPaint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.7, -0.8),
          radius: 1.1,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.12 : 0.36),
            AppTheme.primary.withValues(alpha: isDark ? 0.08 : 0.14),
            Colors.transparent,
          ],
          stops: const [0.0, 0.34, 1.0],
        ).createShader(rect);
      canvas.drawRRect(rrect, hoverPaint);
    }

    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.42 : 1),
          Colors.white.withValues(alpha: isDark ? 0.08 : 0.46),
          Colors.black.withValues(alpha: isDark ? 0.42 : 0.08),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect.deflate(0.8), edgePaint);
  }

  @override
  bool shouldRepaint(covariant _LiquidGlassSurfacePainter oldDelegate) {
    return oldDelegate.isDark != isDark || oldDelegate.hovered != hovered;
  }
}

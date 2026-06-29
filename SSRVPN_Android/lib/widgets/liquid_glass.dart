import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const double _bottomNavBaseOpacity = 0.04; // 96%透明磨砂
const double _bottomNavIndicatorOpacity = 0.18; // 选中指示器

class LiquidGlassNavBar extends StatefulWidget {
  static const double height = 64;
  final int currentIndex;
  final List<NavItem> items;
  final ValueChanged<int> onTap;

  const LiquidGlassNavBar({
    super.key,
    required this.currentIndex,
    required this.items,
    required this.onTap,
  });

  @override
  State<LiquidGlassNavBar> createState() => _LiquidGlassNavBarState();
}

class _LiquidGlassNavBarState extends State<LiquidGlassNavBar>
    with TickerProviderStateMixin {
  static const double _height = 64;
  static const double _innerPadding = 4;
  static const double _bottomGap = 4;
  static const double _horizontalInset = 16; // 缩进避开R角

  late final AnimationController _positionController;
  late Animation<double> _position;
  late final AnimationController _pressController;

  double _dragPx = 0;

  @override
  void initState() {
    super.initState();
    _positionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _position = Tween<double>(
      begin: widget.currentIndex.toDouble(),
      end: widget.currentIndex.toDouble(),
    ).animate(
      CurvedAnimation(parent: _positionController, curve: _LiquidSpringCurve()),
    );
    _positionController.value = 1;

    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 170),
      reverseDuration: const Duration(milliseconds: 260),
    );
  }

  @override
  void didUpdateWidget(covariant LiquidGlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _position = Tween<double>(
        begin: _position.value,
        end: widget.currentIndex.toDouble(),
      ).animate(
        CurvedAnimation(
          parent: _positionController,
          curve: _LiquidSpringCurve(),
        ),
      );
      _positionController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _positionController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(
          _horizontalInset, 0, _horizontalInset, _bottomGap),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fullWidth = constraints.maxWidth;

            return AnimatedBuilder(
              animation: Listenable.merge([
                _positionController,
                _pressController,
              ]),
              builder: (context, _) => _buildBar(context, isDark, fullWidth),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context, bool isDark, double fullWidth) {
    final itemCount = widget.items.length;
    // 导航栏左右缩进避免R角，内部内容居中
    final barInset = 20.0;
    final barWidth = fullWidth - barInset * 2;
    final contentWidth = barWidth - _innerPadding * 2;
    final itemWidth = contentWidth / itemCount;
    final dragFraction = itemWidth == 0 ? 0.0 : _dragPx / itemWidth;
    final maxIndex = (itemCount - 1).toDouble();
    final visualIndex = (_position.value + dragFraction).clamp(0.0, maxIndex);
    final press = _pressController.value;
    final panelOffset = _rubberBandOffset(_dragPx, barWidth);
    final indicatorCenter = _innerPadding + (visualIndex + 0.5) * itemWidth;
    final indicatorLeft = indicatorCenter - itemWidth / 2;

    return Transform.translate(
      offset: Offset(panelOffset, 0),
      child: RepaintBoundary(
        child: SizedBox(
          width: barWidth,
          height: _height,
          child: Stack(
            children: [
              // 胶囊形磨砂导航背景
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      width: barWidth,
                      height: _height,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white
                                .withValues(alpha: _bottomNavBaseOpacity)
                            : Colors.black
                                .withValues(alpha: _bottomNavBaseOpacity),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.12)
                              : Colors.black.withValues(alpha: 0.08),
                          width: 0.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.04),
                            blurRadius: 1,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 导航内容
              Center(
                child: SizedBox(
                  width: barWidth,
                  height: _height,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) => _pressController.forward(),
                    onHorizontalDragUpdate: (details) {
                      final limit = contentWidth * (itemCount - 1) * 1.15;
                      setState(() {
                        _dragPx =
                            (_dragPx + details.delta.dx).clamp(-limit, limit);
                      });
                    },
                    onHorizontalDragEnd: (_) {
                      final target =
                          visualIndex.round().clamp(0, itemCount - 1);
                      setState(() => _dragPx = 0);
                      _pressController.reverse();
                      if (target != widget.currentIndex) widget.onTap(target);
                    },
                    onHorizontalDragCancel: () {
                      setState(() => _dragPx = 0);
                      _pressController.reverse();
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 选中指示器
                        Positioned(
                          left: indicatorLeft,
                          top: _innerPadding,
                          bottom: _innerPadding,
                          width: itemWidth,
                          child: Transform.scale(
                            scaleX: 1 + 0.10 * press,
                            scaleY: 1 - 0.035 * press,
                            child:
                                _GlassIndicator(isDark: isDark, press: press),
                          ),
                        ),
                        // 标签页
                        Padding(
                          padding: const EdgeInsets.all(_innerPadding),
                          child: Row(
                            children: [
                              for (var i = 0; i < widget.items.length; i++)
                                Expanded(
                                  child: _NavCell(
                                    item: widget.items[i],
                                    selected: i == widget.currentIndex,
                                    isDark: isDark,
                                    press: press,
                                    onTapDown: () => _pressController.forward(),
                                    onTapCancel: () =>
                                        _pressController.reverse(),
                                    onTap: () {
                                      _pressController.reverse();
                                      if (i != widget.currentIndex)
                                        widget.onTap(i);
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _rubberBandOffset(double dragPx, double width) {
    if (width <= 0 || dragPx == 0) return 0;
    final fraction = (dragPx / width).clamp(-1.0, 1.0);
    final eased = 1 - math.pow(1 - fraction.abs(), 3);
    return fraction.sign * 4 * eased;
  }
}

class _NavCell extends StatelessWidget {
  final NavItem item;
  final bool selected;
  final bool isDark;
  final double press;
  final VoidCallback onTapDown;
  final VoidCallback onTapCancel;
  final VoidCallback onTap;

  const _NavCell({
    required this.item,
    required this.selected,
    required this.isDark,
    required this.press,
    required this.onTapDown,
    required this.onTapCancel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? const Color(0xFF4D8DFF)
        : (isDark ? Colors.white : const Color(0xFF101318))
            .withValues(alpha: isDark ? 0.88 : 0.62);
    final scale = selected ? 1.0 + 0.10 * press : 1.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => onTapDown(),
      onTapCancel: onTapCancel,
      onTapUp: (_) => onTap(),
      child: Transform.scale(
        scale: scale,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? item.activeIcon : item.icon,
                size: 21, color: color),
            const SizedBox(height: 2),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.visible,
              softWrap: false,
              style: TextStyle(
                color: color,
                fontSize: 11,
                height: 1.2,
                letterSpacing: 0,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassIndicator extends StatelessWidget {
  final bool isDark;
  final double press;

  const _GlassIndicator({required this.isDark, required this.press});

  @override
  Widget build(BuildContext context) {
    return _GlassLayer(
      borderRadius: BorderRadius.circular(28),
      isDark: isDark,
      blurSigma: 14,
      isIndicator: true,
      press: press,
      refractionHeight: 4 + 5 * press,
      refractionAmount: 1.5 + 4 * press,
      depthEffect: true,
      chromaticAberration: 0,
      saturation: 1.04,
      shadowAlpha: 0,
      enableBackdropFilter: false,
      child: const SizedBox.expand(),
    );
  }
}

class _GlassLayer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final bool isDark;
  final bool isIndicator;
  final double blurSigma;
  final double press;
  final double refractionHeight;
  final double refractionAmount;
  final bool depthEffect;
  final double chromaticAberration;
  final double saturation;
  final double shadowAlpha;
  final bool enableBackdropFilter;

  const _GlassLayer({
    required this.child,
    required this.borderRadius,
    required this.isDark,
    this.isIndicator = false,
    this.blurSigma = 4,
    this.press = 0,
    this.refractionHeight = 0,
    this.refractionAmount = 0,
    this.depthEffect = false,
    this.chromaticAberration = 0,
    this.saturation = 1,
    this.shadowAlpha = 0.18,
    this.enableBackdropFilter = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final defaultSurfaceAlpha = isDark ? 0.52 : 0.46;
    final surfaceColor = isIndicator
        ? Colors.transparent
        : isDark
            ? const Color(0xFF151515).withValues(alpha: defaultSurfaceAlpha)
            : colorScheme.surfaceContainer.withValues(
                alpha: defaultSurfaceAlpha,
              );
    final decoration = BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: shadowAlpha <= 0
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: shadowAlpha),
                blurRadius: isDark ? 18 : 12,
                spreadRadius: isDark ? -3 : -4,
                offset: const Offset(0, 8),
              ),
            ],
    );

    return DecoratedBox(
      decoration: decoration,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return ClipRRect(
            borderRadius: borderRadius,
            child: _GlassBackdrop(
              enabled: enableBackdropFilter,
              size: size,
              borderRadius: borderRadius,
              blurSigma: blurSigma,
              refractionHeight: refractionHeight,
              refractionAmount: refractionAmount,
              depthEffect: depthEffect,
              chromaticAberration: chromaticAberration,
              saturation: saturation,
              liquidScale: 0,
              child: _GlassPaint(
                borderRadius: borderRadius,
                isDark: isDark,
                isIndicator: isIndicator,
                press: press,
                surfaceColor: surfaceColor,
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GlassBackdrop extends StatelessWidget {
  final bool enabled;
  final Size size;
  final BorderRadius borderRadius;
  final double blurSigma;
  final double refractionHeight;
  final double refractionAmount;
  final bool depthEffect;
  final double chromaticAberration;
  final double saturation;
  final double liquidScale;
  final Widget child;

  const _GlassBackdrop({
    required this.enabled,
    required this.size,
    required this.borderRadius,
    required this.blurSigma,
    required this.refractionHeight,
    required this.refractionAmount,
    required this.depthEffect,
    required this.chromaticAberration,
    required this.saturation,
    required this.liquidScale,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return _LensBackdropFilter(
      size: size,
      borderRadius: borderRadius,
      blurSigma: blurSigma,
      refractionHeight: refractionHeight,
      refractionAmount: refractionAmount,
      depthEffect: depthEffect,
      chromaticAberration: chromaticAberration,
      saturation: saturation,
      liquidScale: liquidScale,
      child: child,
    );
  }
}

class _GlassPaint extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final bool isDark;
  final bool isIndicator;
  final double press;
  final Color surfaceColor;

  const _GlassPaint({
    required this.child,
    required this.borderRadius,
    required this.isDark,
    required this.isIndicator,
    required this.press,
    required this.surfaceColor,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GlassSurfacePainter(
        borderRadius: borderRadius,
        isDark: isDark,
        isIndicator: isIndicator,
        press: press,
        surfaceColor: surfaceColor,
      ),
      foregroundPainter: _GlassHighlightPainter(
        borderRadius: borderRadius,
        isDark: isDark,
        isIndicator: isIndicator,
        press: press,
      ),
      child: child,
    );
  }
}

class _LensBackdropFilter extends StatelessWidget {
  final Size size;
  final BorderRadius borderRadius;
  final double blurSigma;
  final double refractionHeight;
  final double refractionAmount;
  final bool depthEffect;
  final double chromaticAberration;
  final double saturation;
  final double liquidScale;
  final Widget child;

  const _LensBackdropFilter({
    required this.size,
    required this.borderRadius,
    required this.blurSigma,
    required this.refractionHeight,
    required this.refractionAmount,
    required this.depthEffect,
    required this.chromaticAberration,
    required this.saturation,
    required this.liquidScale,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final blur = ui.ImageFilter.blur(
      sigmaX: blurSigma,
      sigmaY: blurSigma,
      tileMode: ui.TileMode.decal,
    );
    final canUseLens = ui.ImageFilter.isShaderFilterSupported &&
        size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0 &&
        refractionHeight > 0 &&
        refractionAmount > 0;

    if (!canUseLens) {
      return BackdropFilter(filter: blur, child: child);
    }

    return FutureBuilder<ui.FragmentProgram>(
      future: _LiquidLensProgram.load(),
      builder: (context, snapshot) {
        final program = snapshot.data;
        if (program == null || snapshot.hasError) {
          return BackdropFilter(filter: blur, child: child);
        }

        ui.ImageFilter filter = blur;
        try {
          final shader = program.fragmentShader();
          _setLensUniforms(shader, Directionality.of(context));
          filter = ui.ImageFilter.compose(
            outer: ui.ImageFilter.shader(shader),
            inner: blur,
          );
        } catch (_) {
          filter = blur;
        }

        return BackdropFilter(filter: filter, child: child);
      },
    );
  }

  void _setLensUniforms(ui.FragmentShader shader, TextDirection direction) {
    final resolved = borderRadius.resolve(direction);
    final maxRadius = math.min(size.width, size.height) / 2;
    shader
      ..setFloat(2, _radius(resolved.topLeft, maxRadius))
      ..setFloat(3, _radius(resolved.topRight, maxRadius))
      ..setFloat(4, _radius(resolved.bottomRight, maxRadius))
      ..setFloat(5, _radius(resolved.bottomLeft, maxRadius))
      ..setFloat(6, refractionHeight)
      ..setFloat(7, -refractionAmount)
      ..setFloat(8, depthEffect ? 1 : 0)
      ..setFloat(9, chromaticAberration)
      ..setFloat(10, saturation)
      ..setFloat(11, liquidScale);
  }

  double _radius(Radius radius, double maxRadius) {
    return radius.x.clamp(0.0, maxRadius).toDouble();
  }
}

class _LiquidLensProgram {
  static Future<ui.FragmentProgram>? _program;

  static Future<ui.FragmentProgram> load() {
    return _program ??= ui.FragmentProgram.fromAsset(
      'shaders/liquid_lens.frag',
    );
  }
}

class _GlassSurfacePainter extends CustomPainter {
  final BorderRadius borderRadius;
  final bool isDark;
  final bool isIndicator;
  final double press;
  final Color surfaceColor;

  const _GlassSurfacePainter({
    required this.borderRadius,
    required this.isDark,
    required this.isIndicator,
    required this.press,
    required this.surfaceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);
    canvas.save();
    canvas.clipRRect(rrect);

    if (isIndicator) {
      final fill = isDark ? const Color(0xFF383838) : const Color(0xFFFFFFFF);
      canvas.drawRRect(
        rrect,
        Paint()..color = fill.withValues(alpha: _bottomNavIndicatorOpacity),
      );

      if (press > 0.01) {
        canvas.drawRRect(
          rrect,
          Paint()..color = Colors.black.withValues(alpha: 0.06 * press),
        );
      }
    } else {
      canvas.drawRRect(rrect, Paint()..color = surfaceColor);
    }

    final sheen = Paint()
      ..shader = ui.Gradient.linear(
        Offset(size.width * 0.15, 0),
        Offset(size.width * 0.85, size.height),
        [
          Colors.white.withValues(alpha: isIndicator ? 0.13 : 0.07),
          Colors.white.withValues(alpha: isIndicator ? 0.03 : 0.015),
          Colors.black.withValues(
            alpha:
                isIndicator ? (isDark ? 0.10 : 0.02) : (isDark ? 0.025 : 0.01),
          ),
        ],
        const [0, 0.55, 1],
      );
    canvas.drawRect(rect, sheen);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlassSurfacePainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.isIndicator != isIndicator ||
        oldDelegate.press != press ||
        oldDelegate.surfaceColor != surfaceColor ||
        oldDelegate.borderRadius != borderRadius;
  }
}

class _GlassHighlightPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final bool isDark;
  final bool isIndicator;
  final double press;

  const _GlassHighlightPainter({
    required this.borderRadius,
    required this.isDark,
    required this.isIndicator,
    required this.press,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);
    canvas.save();
    canvas.clipRRect(rrect);

    final topGlow = Paint()
      ..shader = ui.Gradient.linear(
        Offset(size.width * 0.5, -size.height * 0.35),
        Offset(size.width * 0.5, size.height * 0.48),
        [
          Colors.white.withValues(
            alpha:
                isIndicator ? (isDark ? 0.18 : 0.48) : (isDark ? 0.09 : 0.24),
          ),
          Colors.white.withValues(
            alpha:
                isIndicator ? (isDark ? 0.055 : 0.18) : (isDark ? 0.025 : 0.08),
          ),
          Colors.transparent,
        ],
        const [0, 0.42, 1],
      );
    canvas.drawRect(rect, topGlow);

    final transparentRim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isIndicator ? 0.82 : 0.72
      ..shader = ui.Gradient.linear(
        Offset(size.width * 0.03, -size.height * 0.12),
        Offset(size.width * 0.94, size.height * 1.04),
        [
          Colors.white.withValues(
            alpha:
                isIndicator ? (isDark ? 0.46 : 0.56) : (isDark ? 0.25 : 0.36),
          ),
          Colors.white.withValues(
            alpha:
                isIndicator ? (isDark ? 0.16 : 0.22) : (isDark ? 0.08 : 0.13),
          ),
          Colors.transparent,
          Colors.white.withValues(
            alpha:
                isIndicator ? (isDark ? 0.12 : 0.16) : (isDark ? 0.05 : 0.08),
          ),
        ],
        const [0, 0.18, 0.66, 1],
      )
      ..blendMode = BlendMode.plus
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.45);
    canvas.drawRRect(rrect.deflate(0.7), transparentRim);

    final topEdgeHighlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isIndicator ? 0.56 : 0.48
      ..shader = ui.Gradient.linear(
        Offset(size.width * 0.16, 0),
        Offset(size.width * 0.82, size.height * 0.44),
        [
          Colors.white.withValues(
            alpha:
                isIndicator ? (isDark ? 0.34 : 0.46) : (isDark ? 0.17 : 0.30),
          ),
          Colors.white.withValues(
            alpha:
                isIndicator ? (isDark ? 0.10 : 0.16) : (isDark ? 0.04 : 0.08),
          ),
          Colors.transparent,
        ],
        const [0, 0.38, 1],
      )
      ..blendMode = BlendMode.plus;
    canvas.drawRRect(rrect.deflate(1.6), topEdgeHighlight);

    final borderBloom = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.72
      ..color = Colors.white.withValues(
        alpha: isIndicator ? 0.11 + 0.04 * press : 0.035,
      )
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.1);
    canvas.drawRRect(rrect.deflate(0.9), borderBloom);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isIndicator ? 0.58 : 0.64
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, size.height),
        [
          Colors.white.withValues(alpha: isDark ? 0.22 : 0.44),
          Colors.white.withValues(alpha: isDark ? 0.07 : 0.14),
          Colors.black.withValues(
            alpha:
                isIndicator ? (isDark ? 0.14 : 0.02) : (isDark ? 0.06 : 0.01),
          ),
        ],
        const [0, 0.58, 1],
      );
    canvas.drawRRect(rrect.deflate(0.45), border);

    if (isIndicator && press > 0.01) {
      final innerShadow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black.withValues(alpha: 0.18 * press)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 * press);
      canvas.drawRRect(rrect.deflate(1.2), innerShadow);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlassHighlightPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.isIndicator != isIndicator ||
        oldDelegate.press != press ||
        oldDelegate.borderRadius != borderRadius;
  }
}

class _LiquidSpringCurve extends Curve {
  @override
  double transformInternal(double t) {
    if (t == 0 || t == 1) return t;
    final eased = 1 - math.pow(1 - t, 3).toDouble();
    final overshoot = math.sin(t * math.pi) * 0.035 * (1 - t);
    return (eased + overshoot).clamp(0.0, 1.0);
  }
}

class NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

class LiquidGlassButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double borderRadius;

  const LiquidGlassButton({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = 14,
  });

  @override
  State<LiquidGlassButton> createState() => _LiquidGlassButtonState();
}

class _LiquidGlassButtonState extends State<LiquidGlassButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
            scale: 1 - _controller.value * 0.035,
            child: _GlassLayer(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              isDark: isDark,
              blurSigma: 4,
              refractionHeight: 12,
              refractionAmount: 12,
              saturation: 1.35,
              press: _controller.value,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: widget.child,
              ),
            ),
          );
        },
      ),
    );
  }
}

class GlassInputDecoration extends InputDecoration {
  final bool isDark;

  GlassInputDecoration({
    required this.isDark,
    super.hintText,
    super.labelText,
    super.prefixIcon,
  }) : super(
          filled: true,
          fillColor: isDark
              ? Colors.white.withValues(alpha: 10 / 255)
              : Colors.white.withValues(alpha: 25 / 255),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: (isDark ? 15 : 30) / 255),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: (isDark ? 15 : 30) / 255),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF7B68EE), width: 1.5),
          ),
          hintStyle: TextStyle(
            color: isDark
                ? Colors.white.withValues(alpha: 70 / 255)
                : Colors.black.withValues(alpha: 70 / 255),
          ),
          labelStyle: TextStyle(
            color: isDark
                ? Colors.white.withValues(alpha: 100 / 255)
                : Colors.black.withValues(alpha: 120 / 255),
          ),
        );
}

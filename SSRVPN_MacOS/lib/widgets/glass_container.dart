import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Premium Glass Container
class GlassContainer extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double? blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final bool enablePress;
  final Color? bgColor;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 16,
    this.blur,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.enablePress = true,
    this.bgColor,
  });

  @override
  State<GlassContainer> createState() => _GlassContainerState();
}

class _GlassContainerState extends State<GlassContainer>
    with SingleTickerProviderStateMixin {
  AnimationController? _pressCtrl;
  Animation<double>? _scaleAnim;

  @override
  void initState() {
    super.initState();
    if (widget.enablePress) {
      _pressCtrl = AnimationController(
          vsync: this, duration: const Duration(milliseconds: 100));
      _scaleAnim = Tween(begin: 1.0, end: 0.985).animate(
          CurvedAnimation(parent: _pressCtrl!, curve: Curves.easeOutCubic));
    }
  }

  @override
  void dispose() {
    _pressCtrl?.dispose();
    super.dispose();
  }

  double _blur(BuildContext c) {
    if (widget.blur != null) return widget.blur!;
    final dpr = MediaQuery.of(c).devicePixelRatio;
    final pixels =
        MediaQuery.of(c).size.width * MediaQuery.of(c).size.height * dpr * dpr;
    return pixels > 2000000
        ? 24
        : pixels > 1000000
            ? 12
            : 0;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sigma = _blur(context);

    Widget card = Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      padding: widget.padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        color: widget.bgColor ??
            (isDark
                ? const Color(0xFF101827).withValues(alpha: 0.74)
                : Colors.white.withValues(alpha: 0.62)),
        gradient: widget.bgColor == null && isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF22304A).withValues(alpha: 0.72),
                  const Color(0xFF101827).withValues(alpha: 0.78),
                  const Color(0xFF07101C).withValues(alpha: 0.82),
                  AppTheme.primary.withValues(alpha: 0.08),
                ],
                stops: const [0.0, 0.4, 0.78, 1.0],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.8),
                  Colors.white.withValues(alpha: 0.42),
                  AppTheme.primary.withValues(alpha: 0.08),
                ],
              ),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.72),
          width: 0.7,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.08),
            blurRadius: 30,
            spreadRadius: -12,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: widget.child,
    );

    if (sigma > 0) {
      card = ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: card),
      );
    }

    final ctrl = _pressCtrl;
    final anim = _scaleAnim;
    if (ctrl != null && anim != null) {
      card = GestureDetector(
        onTapDown: (_) => ctrl.forward(),
        onTapUp: (_) => ctrl.reverse(),
        onTapCancel: () => ctrl.reverse(),
        child: AnimatedBuilder(
          animation: ctrl,
          builder: (_, child) =>
              Transform.scale(scale: anim.value, child: child),
          child: card,
        ),
      );
    }
    return RepaintBoundary(child: card);
  }
}

/// Premium input decoration
class GlassInputDecoration extends InputDecoration {
  GlassInputDecoration(
      {required bool isDark, super.hintText, super.labelText, super.prefixIcon})
      : super(
          filled: true,
          isDense: true,
          fillColor: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.white.withValues(alpha: 0.5),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.2))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.2))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: AppTheme.primary.withValues(alpha: 0.6), width: 1.5)),
          hintStyle: TextStyle(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.35)
                  : Colors.black.withValues(alpha: 0.35)),
          labelStyle: TextStyle(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.5)
                  : Colors.black.withValues(alpha: 0.5)),
        );
}

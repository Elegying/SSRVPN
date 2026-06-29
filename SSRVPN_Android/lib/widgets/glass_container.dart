import 'dart:ui';
import 'package:flutter/material.dart';

/// 液态玻璃效果容器 — 精简版，无背景动画，无鼠标光晕
class GlassContainer extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double? blur; // null = 自适应
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final bool enableShadow;
  final bool enablePress;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 16,
    this.blur,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.enableShadow = true,
    this.enablePress = true,
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
        vsync: this,
        duration: const Duration(milliseconds: 150),
      );
      _scaleAnim = Tween<double>(begin: 1.0, end: 0.97).animate(
        CurvedAnimation(parent: _pressCtrl!, curve: Curves.easeOutCubic),
      );
    }
  }

  @override
  void dispose() {
    _pressCtrl?.dispose();
    super.dispose();
  }

  double _adaptiveBlur(BuildContext context) {
    if (widget.blur != null) return widget.blur!;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final size = MediaQuery.of(context).size;
    final pixels = size.width * size.height * dpr * dpr;
    if (pixels > 2000000) return 20;
    if (pixels > 1000000) return 10;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurSigma = _adaptiveBlur(context);

    Widget child = Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: widget.enableShadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: (isDark ? 60 : 30) / 255),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                  spreadRadius: -6,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: blurSigma > 0
            ? BackdropFilter(
                filter: ImageFilter.blur(
                    sigmaX: blurSigma, sigmaY: blurSigma),
                child: _buildGlass(isDark),
              )
            : _buildGlass(isDark),
      ),
    );

    // 只在需要按压效果时包裹动画和手势
    if (widget.enablePress && _pressCtrl != null && _scaleAnim != null) {
      child = AnimatedBuilder(
        animation: _pressCtrl!,
        builder: (context, animChild) {
          return Transform.scale(
            scale: _scaleAnim!.value,
            child: animChild,
          );
        },
        child: child,
      );
      child = GestureDetector(
        onTapDown: (_) => _pressCtrl!.forward(),
        onTapUp: (_) => _pressCtrl!.reverse(),
        onTapCancel: () => _pressCtrl!.reverse(),
        child: child,
      );
    }

    return RepaintBoundary(child: child);
  }

  Widget _buildGlass(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        // 简单渐变，无动画
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  Colors.white.withValues(alpha: 12 / 255),
                  Colors.white.withValues(alpha: 6 / 255),
                ]
              : [
                  Colors.white.withValues(alpha: 40 / 255),
                  Colors.white.withValues(alpha: 20 / 255),
                ],
        ),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 18 / 255)
              : Colors.white.withValues(alpha: 35 / 255),
          width: 0.5,
        ),
      ),
      padding: widget.padding,
      child: widget.child,
    );
  }
}

/// 液态玻璃风格输入框装饰
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
            borderSide: BorderSide(
              color: const Color(0xFF7B68EE).withValues(alpha: 150 / 255),
              width: 1.5,
            ),
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

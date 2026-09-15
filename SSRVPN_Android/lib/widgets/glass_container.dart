import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_glass.dart';
import 'package:flutter/material.dart';

/// 液态玻璃效果容器 — 精简版，无背景动画，无鼠标光晕
class GlassContainer extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double? blur; // 兼容旧调用；实际材质统一由特效档位决定。
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final bool enableShadow; // 兼容旧调用；阴影统一由共享材质管理。
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

  @override
  Widget build(BuildContext context) {
    Widget child = Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      child: SsrvpnLiquidSurface(
          radius: widget.borderRadius,
          padding: widget.padding ?? EdgeInsets.zero,
          child: widget.child),
    );

    // 只在需要按压效果时包裹动画和手势
    if (widget.enablePress &&
        !ssrvpnUsesLowEffects(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        _pressCtrl != null &&
        _scaleAnim != null) {
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

part of desktop_glass_container;

/// Premium Glass Container
class GlassContainer extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double? blur; // Compatibility only; the shared quality tier controls blur.
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
        vsync: this,
        duration: const Duration(milliseconds: 100),
      );
      _scaleAnim = Tween(begin: 1.0, end: 0.985).animate(
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
    Widget card = Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      child: SsrvpnLiquidSurface(
          radius: widget.borderRadius,
          padding: widget.padding ?? EdgeInsets.zero,
          tint: widget.bgColor,
          child: widget.child),
    );

    final ctrl = _pressCtrl;
    final anim = _scaleAnim;
    if (!ssrvpnUsesLowEffects(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        ctrl != null &&
        anim != null) {
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
  GlassInputDecoration({
    required bool isDark,
    super.hintText,
    super.labelText,
    super.prefixIcon,
  }) : super(
          filled: true,
          isDense: true,
          fillColor: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.white.withValues(alpha: 0.5),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.2),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.2),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: AppTheme.primary.withValues(alpha: 0.6),
              width: 1.5,
            ),
          ),
          hintStyle: TextStyle(
            color: isDark
                ? Colors.white.withValues(alpha: 0.35)
                : Colors.black.withValues(alpha: 0.35),
          ),
          labelStyle: TextStyle(
            color: isDark
                ? Colors.white.withValues(alpha: 0.5)
                : Colors.black.withValues(alpha: 0.5),
          ),
        );
}

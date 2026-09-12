import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Animate only the wallpaper; foreground controls remain still and reusable.
class SsrvpnDriftingBackground extends StatefulWidget {
  const SsrvpnDriftingBackground({super.key, required this.child});
  final Widget child;
  @override
  State<SsrvpnDriftingBackground> createState() =>
      _SsrvpnDriftingBackgroundState();
}

class _SsrvpnDriftingBackgroundState extends State<SsrvpnDriftingBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _motion =
      AnimationController(vsync: this, duration: const Duration(seconds: 32));
  bool _reducedMotion = true;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    // A translucent popup leaves the underlying route mounted. Pause its
    // decorative motion so every obscured glass card does not rasterize again.
    _visible = TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _updateMotion();

  void _updateMotion() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final active = !_reducedMotion &&
        _visible &&
        (lifecycle == AppLifecycleState.resumed ||
            lifecycle == AppLifecycleState.inactive);
    if (active && !_motion.isAnimating) {
      _motion.repeat();
    } else if (!active) {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
        child: AnimatedBuilder(
          animation: _motion,
          child: ExcludeSemantics(child: RepaintBoundary(child: widget.child)),
          builder: (context, child) {
            // A full cosine cycle matches position and velocity at both seams.
            final t = (1 - math.cos(_motion.value * 2 * math.pi)) / 2;
            return Transform.scale(
              scale: 1.10,
              child: FractionalTranslation(
                translation: Offset((t - .5) * .07, (.5 - t) * .05),
                child: child,
              ),
            );
          },
        ),
      );
}

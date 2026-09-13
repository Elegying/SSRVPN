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
      AnimationController(vsync: this, duration: const Duration(seconds: 18));
  bool _reducedMotion = true;
  bool _visible = true;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    final route = ModalRoute.of(context);
    if (_route != route) {
      _listenToRoute(false);
      _route = route;
      _listenToRoute(true);
    }
    // A translucent popup leaves the underlying route mounted. Pause its
    // decorative motion so every obscured glass card does not rasterize again.
    _visible = TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _updateMotion();

  void _listenToRoute(bool add) {
    for (final animation in [_route?.animation, _route?.secondaryAnimation]) {
      if (add) {
        animation?.addStatusListener(_routeStatusChanged);
      } else {
        animation?.removeStatusListener(_routeStatusChanged);
      }
    }
  }

  void _routeStatusChanged(AnimationStatus _) => _updateMotion();

  void _updateMotion() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final active = !_reducedMotion &&
        _visible &&
        lifecycle == AppLifecycleState.resumed &&
        (_route?.animation == null ||
            _route!.animation!.status == AnimationStatus.completed) &&
        (_route?.secondaryAnimation == null ||
            _route!.secondaryAnimation!.status == AnimationStatus.dismissed);
    if (active && !_motion.isAnimating) {
      _motion.repeat();
    } else if (!active) {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _listenToRoute(false);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
        child: AnimatedBuilder(
          animation: _motion,
          // The capture source already isolates the wallpaper from foreground
          // paints. A nested boundary hides late image/placeholder repaints
          // from that source while motion is paused, leaving its texture stale.
          child: ExcludeSemantics(child: widget.child),
          builder: (context, child) {
            // A full cosine cycle matches position and velocity at both seams.
            final t = (1 - math.cos(_motion.value * 2 * math.pi)) / 2;
            return Transform.scale(
              scale: 1.16,
              child: FractionalTranslation(
                translation: Offset((t - .5) * .11, (.5 - t) * .08),
                child: child,
              ),
            );
          },
        ),
      );
}

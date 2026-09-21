import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Animate only the wallpaper; foreground controls remain still and reusable.
class SsrvpnDriftingBackground extends StatefulWidget {
  const SsrvpnDriftingBackground(
      {super.key, required this.child, this.drift = false});

  /// When false the wallpaper keeps its framing but never moves. Nothing is
  /// scheduled per frame, so neither this surface nor the glass above it
  /// repaints while the app sits idle.
  ///
  /// The default matches the product default (still wallpaper). Leaving it at
  /// `true` would silently opt a future call site back into per-frame repaints,
  /// so any surface that really wants motion must ask for it explicitly.
  final bool drift;
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

  /// The preference can change while this widget stays mounted, so a toggle
  /// has to start or freeze the motion immediately.
  @override
  void didUpdateWidget(covariant SsrvpnDriftingBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drift != widget.drift) _updateMotion();
  }

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
    final active = widget.drift &&
        !_reducedMotion &&
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
        child: widget.drift
            ? AnimatedBuilder(
                animation: _motion,
                // The capture source already isolates the wallpaper from
                // foreground paints. A nested boundary hides late
                // image/placeholder repaints from that source while motion is
                // paused, leaving its texture stale.
                child: ExcludeSemantics(child: widget.child),
                builder: (context, child) => _framed(child!, _motion.value),
              )
            : _framed(ExcludeSemantics(child: widget.child), _motion.value),
      );

  /// A full cosine cycle matches position and velocity at both seams. A
  /// wallpaper that was switched off keeps the phase it froze at, so nothing
  /// jumps the moment the preference changes.
  Widget _framed(Widget child, double value) {
    final t = (1 - math.cos(value * 2 * math.pi)) / 2;
    return Transform.scale(
      scale: 1.16,
      child: FractionalTranslation(
        translation: Offset((t - .5) * .11, (.5 - t) * .08),
        child: child,
      ),
    );
  }
}

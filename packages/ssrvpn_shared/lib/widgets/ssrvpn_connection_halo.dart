import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A local, paint-only halo. The button keeps its layout and glass layer.
class SsrvpnConnectionHalo extends StatefulWidget {
  const SsrvpnConnectionHalo({
    super.key,
    required this.enabled,
    required this.size,
    required this.color,
    required this.child,
  });
  final bool enabled;
  final double size;
  final Color color;
  final Widget child;

  @override
  State<SsrvpnConnectionHalo> createState() => _ConnectionHaloState();
}

class _ConnectionHaloState extends State<SsrvpnConnectionHalo>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600));
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _sync();
  }

  @override
  void didUpdateWidget(SsrvpnConnectionHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  /// Whether the host currently has nothing to hide this surface behind.
  ///
  /// A definite `paused`/`detached`/`hidden` means the window is gone:
  /// `hidden` is what the engine reports for a minimized desktop window, so a
  /// minimized window must not keep pulsing. `inactive` is an ordinary desktop
  /// focus change and must not stall the pulse mid cycle. An *unreported*
  /// state (`null`) is deliberately **not** treated as active: this controller
  /// repeats forever, so guessing "active" on a missing state would spin the
  /// animation on a host that never reports lifecycle at all. Waiting for a
  /// first definite `resumed` is the safe reading, and the `inactive` case
  /// above is what actually fixes focus flicker.
  bool get _hostActive =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive;

  void _sync() {
    final animate = widget.enabled && _visible && _hostActive;
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!animate) {
      _pulse.stop();
    }
    if (!widget.enabled) _pulse.value = 0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (widget.enabled && _visible)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: OverflowBox(
                    maxWidth: widget.size * 1.26,
                    maxHeight: widget.size * 1.26,
                    child: SizedBox.square(
                      dimension: widget.size * 1.26,
                      child: RepaintBoundary(
                        child: CustomPaint(
                          key: const Key('ssrvpn-connected-halo'),
                          painter: _HaloPainter(_pulse, widget.color),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          widget.child,
        ],
      );
}

class _HaloPainter extends CustomPainter {
  _HaloPainter(this.phase, this.color) : super(repaint: phase);
  final Animation<double> phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = phase.value;
    final alpha = .34 * math.sin(math.pi * t);
    if (alpha <= 0) return;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 1.26 * .5 * (1 + .22 * t);
    final shader = RadialGradient(
      colors: [
        color.withValues(alpha: 0),
        color.withValues(alpha: 0),
        color.withValues(alpha: alpha),
        color.withValues(alpha: 0),
      ],
      stops: const [0, .84, .94, 1],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_HaloPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.color != color;
}

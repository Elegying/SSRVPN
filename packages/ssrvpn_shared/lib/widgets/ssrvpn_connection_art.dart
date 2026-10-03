import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import 'ssrvpn_aurora_dial.dart';
import 'ssrvpn_dusk_dial.dart';

/// Decorative, state-driven motion; the live connection action stays stationary.
class SsrvpnConnectionArtwork extends StatefulWidget {
  const SsrvpnConnectionArtwork(
      {super.key, required this.variant, required this.active});
  final AppThemeVariant variant;
  final bool active;
  @override
  State<SsrvpnConnectionArtwork> createState() => _ConnectionArtworkState();
}

class _ConnectionArtworkState extends State<SsrvpnConnectionArtwork>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _clock;
  bool _foreground = true;
  bool _enabled = false;
  Duration get _period => Duration(
      seconds: widget.variant == AppThemeVariant.aurora
          ? 24
          : widget.variant == AppThemeVariant.sakura
              ? 7
              : 4);
  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: _period);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SsrvpnConnectionArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.variant != widget.variant) {
      _clock.stop();
      _clock.value = 0;
      _clock.duration = _period;
      _enabled = false;
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final enabled = widget.active &&
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.highContrastOf(context);
    if (enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) {
      _clock.repeat();
    } else {
      _clock.stop();
      _clock.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
      child: IgnorePointer(
          child: AnimatedBuilder(
              animation: _clock,
              builder: (context, child) {
                if (widget.variant == AppThemeVariant.aurora) {
                  return SsrvpnAuroraDial(rotation: _clock.value * math.pi * 2);
                }
                final sakura = widget.variant == AppThemeVariant.sakura;
                return Stack(fit: StackFit.expand, children: [
                  if (sakura)
                    const FractionallySizedBox(
                        widthFactor: .65,
                        heightFactor: .65,
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(colors: [
                                  Color(0xF7FFFFFF),
                                  Color(0xDDFFE5ED)
                                ])))),
                  child!,
                  if (_enabled)
                    CustomPaint(
                        painter: _ConnectionAccents(
                            phase: _clock.value, sakura: sakura)),
                ]);
              },
              child: widget.variant == AppThemeVariant.aurora
                  ? null
                  : widget.variant == AppThemeVariant.dusk
                      ? const SsrvpnDuskDial()
                      : Image.asset(
                          'assets/themes/${widget.variant.name}-control.webp',
                          package: 'ssrvpn_shared',
                          fit: BoxFit.contain,
                          excludeFromSemantics: true))));
}

class _ConnectionAccents extends CustomPainter {
  const _ConnectionAccents({required this.phase, required this.sakura});
  final double phase;
  final bool sakura;
  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide;
    final center = size.center(Offset.zero);
    if (!sakura) {
      for (var i = 0; i < 2; i++) {
        final progress = (phase + i * .5) % 1;
        final opacity = math.sin(progress * math.pi) * .42;
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = unit * .008
          ..color = const Color(0xFFFFC39A).withValues(alpha: opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, unit * .009);
        canvas.drawCircle(center, unit * (.37 + progress * .12), paint);
      }
      return;
    }
    for (var i = 0; i < 9; i++) {
      final progress = (phase + i / 9) % 1;
      final x =
          .12 + (i * .137 % .76) + math.sin(progress * math.pi * 2 + i) * .045;
      final y = .08 + progress * .82;
      final opacity = math.sin(progress * math.pi) * .8;
      final radius = unit * (.018 + (i % 3) * .004);
      canvas.save();
      canvas.translate(size.width * x, size.height * y);
      canvas.rotate(i + progress * math.pi * .75);
      final petal = Path()
        ..moveTo(0, -radius)
        ..cubicTo(radius * 1.2, -radius, radius, radius * .65, 0, radius)
        ..cubicTo(-radius, radius * .45, -radius * .8, -radius, 0, -radius);
      canvas.drawPath(petal,
          Paint()..color = const Color(0xFFF49ABC).withValues(alpha: opacity));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConnectionAccents old) =>
      old.phase != phase || old.sakura != sakura;
}

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;

/// Fade the glass material itself, never an offscreen layer containing a
/// backdrop filter. Material's default FadeTransition can desynchronize the
/// sampled background from its content during rapid dialog transitions.
Future<T?> showSsrvpnGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = _GlassDialogRoute<T>(
    context: context,
    builder: builder,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierDismissible: barrierDismissible,
    barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final result = await navigator.push<T>(route);
  // Keep callers' re-entry guards held until the outgoing glass is removed.
  await route.completed;
  return result;
}

class _GlassDialogRoute<T> extends DialogRoute<T> {
  _GlassDialogRoute({
    required super.context,
    required super.builder,
    required super.themes,
    required super.barrierDismissible,
    required super.barrierColor,
    required super.traversalEdgeBehavior,
  });

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return glass.GlassMaterializeTransition(
      animation: animation,
      // Keep sampling geometry stationary throughout opening and closing.
      scaleFrom: 1,
      contentSigma: 0,
      child: child,
    );
  }
}

/// Page navigation must not wrap live glass in the platform's default opacity
/// or snapshot transition either, especially when scrolling during entry.
class SsrvpnGlassPageRoute<T> extends MaterialPageRoute<T> {
  SsrvpnGlassPageRoute({required super.builder, super.settings})
      : super(allowSnapshotting: false);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    // Animate only the clip. Full-size layout and shader coordinates stay fixed;
    // no ancestor opacity/saveLayer, scale or page snapshot is introduced.
    return ClipRect(
      clipper: _GlassPageRevealClipper(animation),
      clipBehavior: Clip.hardEdge,
      child: child,
    );
  }
}

class _GlassPageRevealClipper extends CustomClipper<Rect> {
  _GlassPageRevealClipper(this.animation) : super(reclip: animation);
  final Animation<double> animation;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width,
      size.height * Curves.easeOutCubic.transform(animation.value));
  @override
  bool shouldReclip(_GlassPageRevealClipper oldClipper) =>
      animation != oldClipper.animation;
}

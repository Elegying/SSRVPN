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
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: animation.status == AnimationStatus.reverse,
      child: reducedMotion
          ? child
          : glass.GlassMaterializeTransition(
              animation: animation,
              // Keep sampling geometry stationary throughout opening and closing.
              scaleFrom: 1,
              contentSigma: 0,
              child: child,
            ),
    );
  }
}

/// Page navigation must not wrap live glass in the platform's default opacity
/// or snapshot transition either, especially when scrolling during entry.
class SsrvpnGlassPageRoute<T> extends MaterialPageRoute<T> {
  SsrvpnGlassPageRoute({required super.builder, super.settings})
      : super(allowSnapshotting: false);

  // The Android theme otherwise fades the previous Material route to its
  // scaffold color while this route slides, exposing a black half-screen.
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 260);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    // Translate without scaling or fading the shader layer. The background and
    // its glass move together; reversing the route continues from its position.
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(animation.drive(CurveTween(curve: Curves.easeInOutCubic))),
      child: child,
    );
  }
}

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

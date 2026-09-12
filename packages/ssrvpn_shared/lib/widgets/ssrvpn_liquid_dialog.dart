import 'package:flutter/material.dart';
import 'ssrvpn_liquid_glass.dart';

/// Liquid surface with Flutter's keyboard insets and dialog semantics.
class SsrvpnLiquidDialog extends StatelessWidget {
  const SsrvpnLiquidDialog(
      {super.key,
      required this.child,
      this.insetPadding =
          const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      this.backgroundColor,
      this.elevation,
      this.shape});
  final Widget child;
  final EdgeInsets insetPadding;
  final Color? backgroundColor;
  final double? elevation;
  final ShapeBorder? shape;
  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: insetPadding,
        child: SsrvpnLiquidSurface(radius: 20, child: child),
      );
}

/// Standard alert content/actions on the same material as our tutorial panels.
class SsrvpnLiquidAlertDialog extends StatelessWidget {
  const SsrvpnLiquidAlertDialog(
      {super.key,
      this.title,
      this.content,
      this.actions,
      this.scrollable = false,
      this.backgroundColor,
      this.contentPadding = const EdgeInsets.fromLTRB(24, 16, 24, 20)});
  final Widget? title, content;
  final List<Widget>? actions;
  final bool scrollable;
  final Color? backgroundColor;
  final EdgeInsetsGeometry contentPadding;
  @override
  Widget build(BuildContext context) => SsrvpnLiquidDialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
                child: SingleChildScrollView(
                    child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                      child: Semantics(
                          namesRoute: true,
                          child: DefaultTextStyle(
                              style: Theme.of(context).textTheme.titleLarge!,
                              child: title!))),
                if (content != null)
                  Padding(
                      padding: contentPadding,
                      child: DefaultTextStyle(
                          style: Theme.of(context).textTheme.bodyMedium!,
                          child: content!)),
              ],
            ))),
            if (actions != null && actions!.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      spacing: 8,
                      overflowSpacing: 8,
                      children: actions!)),
          ]),
        ),
      );
}

/// Small context menus share the dialog material without changing route behavior.
Future<T?> showSsrvpnLiquidMenu<T>(
        {required BuildContext context,
        required RelativeRect position,
        required List<PopupMenuEntry<T>> items}) =>
    showMenu<T>(
        context: context,
        position: position,
        items: items,
        color: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        menuPadding: EdgeInsets.zero);

class SsrvpnLiquidMenuItem<T> extends PopupMenuItem<T> {
  SsrvpnLiquidMenuItem({super.key, super.value, required Widget child})
      : super(
            padding: EdgeInsets.zero,
            child: SsrvpnLiquidSurface(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: child));
}

part of 'ssrvpn_node_selection_page.dart';

class _KeyboardActivate extends StatefulWidget {
  const _KeyboardActivate({
    required this.enabled,
    required this.onActivate,
    required this.debugLabel,
    required this.focusRadius,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onActivate;
  final String debugLabel;
  final double focusRadius;
  final Widget child;

  @override
  State<_KeyboardActivate> createState() => _KeyboardActivateState();
}

class _KeyboardActivateState extends State<_KeyboardActivate> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      debugLabel: widget.debugLabel,
      canRequestFocus: widget.enabled,
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
      },
      onKeyEvent: (_, event) {
        if (widget.enabled &&
            event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        key: ValueKey('ssrvpn-keyboard-focus-${widget.debugLabel}'),
        duration: const Duration(milliseconds: 120),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.focusRadius),
          border: _focused
              ? Border.all(color: SsrvpnUiTokens.primary, width: 2)
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

import 'package:ssrvpn_shared/widgets/ssrvpn_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show SsrvpnDesktopTitlebarInset;
import 'package:window_manager/window_manager.dart';

import '../startup/startup_logger.dart';

const double windowsTitleBarHeight = 40;

class WindowsDesktopFrame extends StatelessWidget {
  const WindowsDesktopFrame({super.key, required this.child});
  final Widget child;
  void _runWindowAction(String actionName, Future<void> Function() action) {
    unawaited(() async {
      try {
        await action();
      } catch (error, stack) {
        StartupLogger.error('$actionName window action failed', error, stack);
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SsrvpnTheme.of(context).background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SsrvpnDesktopTitlebarInset(
            top: windowsTitleBarHeight,
            child: child,
          ),
          Align(
            alignment: Alignment.topCenter,
            child: WindowsTitleBar(
              onMinimize: () =>
                  _runWindowAction('Minimize', windowManager.minimize),
              onClose: () => _runWindowAction('Close', windowManager.close),
            ),
          ),
        ],
      ),
    );
  }
}

class WindowsTitleBar extends StatelessWidget {
  const WindowsTitleBar({
    super.key,
    required this.onMinimize,
    required this.onClose,
  });

  final VoidCallback onMinimize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: Key('windows-custom-title-bar'),
      height: windowsTitleBarHeight,
      child: Row(
        children: [
          Expanded(
              child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: (_) => windowManager.startDragging(),
                  child: const SizedBox.expand())),
          _CaptionButton(
            tooltip: '最小化',
            icon: Icons.remove_rounded,
            onPressed: onMinimize,
          ),
          _CaptionButton(
            tooltip: '关闭',
            icon: Icons.close_rounded,
            destructive: true,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 16,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(
        width: 46,
        height: windowsTitleBarHeight,
      ),
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(
          Size(46, windowsTitleBarHeight),
        ),
        maximumSize: WidgetStatePropertyAll(
          Size(46, windowsTitleBarHeight),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          final highlighted = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed);
          if (destructive && highlighted) return Colors.white;
          return SsrvpnTheme.of(context).textSecondary;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          final highlighted = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed);
          if (!highlighted) return Colors.transparent;
          return destructive
              ? SsrvpnTheme.of(context).error
              : SsrvpnTheme.of(context).surface;
        }),
        overlayColor: WidgetStatePropertyAll(Colors.transparent),
      ),
      icon: Icon(icon),
    );
  }
}

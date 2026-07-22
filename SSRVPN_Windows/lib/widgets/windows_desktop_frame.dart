import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show SsrvpnDesktopTitlebarInset;
import 'package:window_manager/window_manager.dart';

import '../startup/startup_logger.dart';
import '../theme/app_theme.dart';

const double windowsTitleBarHeight = 40;
const double windowsWindowCornerRadius = 14;

double resolveWindowsWindowCornerRadius(bool isMaximized) {
  return isMaximized ? 0 : windowsWindowCornerRadius;
}

class WindowsDesktopFrame extends StatefulWidget {
  const WindowsDesktopFrame({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<WindowsDesktopFrame> createState() => _WindowsDesktopFrameState();
}

class _WindowsDesktopFrameState extends State<WindowsDesktopFrame>
    with WindowListener {
  bool _isMaximized = false;
  bool _listenerAttached = false;

  @override
  void initState() {
    super.initState();
    try {
      windowManager.addListener(this);
      _listenerAttached = true;
    } catch (error, stack) {
      StartupLogger.error('Attach custom window listener failed', error, stack);
    }
    unawaited(_refreshMaximizedState());
  }

  @override
  void dispose() {
    if (_listenerAttached) {
      try {
        windowManager.removeListener(this);
      } catch (error, stack) {
        StartupLogger.error(
            'Detach custom window listener failed', error, stack);
      }
    }
    super.dispose();
  }

  Future<void> _refreshMaximizedState() async {
    try {
      final isMaximized = await windowManager.isMaximized();
      if (mounted && isMaximized != _isMaximized) {
        setState(() => _isMaximized = isMaximized);
      }
    } catch (error, stack) {
      StartupLogger.error('Read maximized window state failed', error, stack);
    }
  }

  void _runWindowAction(
    String actionName,
    Future<void> Function() action,
  ) {
    unawaited(() async {
      try {
        await action();
      } catch (error, stack) {
        StartupLogger.error('$actionName window action failed', error, stack);
      }
    }());
  }

  @override
  void onWindowMaximize() {
    if (mounted && !_isMaximized) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted && _isMaximized) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        resolveWindowsWindowCornerRadius(_isMaximized),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SsrvpnDesktopTitlebarInset(
              top: windowsTitleBarHeight,
              child: widget.child,
            ),
            Align(
              alignment: Alignment.topCenter,
              child: WindowsTitleBar(
                isMaximized: _isMaximized,
                onMinimize: () =>
                    _runWindowAction('Minimize', windowManager.minimize),
                onToggleMaximize: () => _runWindowAction(
                  _isMaximized ? 'Restore' : 'Maximize',
                  _isMaximized
                      ? windowManager.unmaximize
                      : windowManager.maximize,
                ),
                onClose: () => _runWindowAction('Close', windowManager.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WindowsTitleBar extends StatelessWidget {
  const WindowsTitleBar({
    super.key,
    required this.isMaximized,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  final bool isMaximized;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('windows-custom-title-bar'),
      height: windowsTitleBarHeight,
      child: Row(
        children: [
          const Expanded(
            child: DragToMoveArea(
              child: SizedBox.expand(),
            ),
          ),
          _CaptionButton(
            tooltip: '最小化',
            icon: Icons.remove_rounded,
            onPressed: onMinimize,
          ),
          _CaptionButton(
            tooltip: isMaximized ? '还原' : '最大化',
            icon: isMaximized ? Icons.filter_none_rounded : Icons.crop_square,
            iconSize: isMaximized ? 13 : 12,
            onPressed: onToggleMaximize,
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
    this.iconSize = 16,
    this.destructive = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double iconSize;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: iconSize,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: 46,
        height: windowsTitleBarHeight,
      ),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(46, windowsTitleBarHeight),
        ),
        maximumSize: const WidgetStatePropertyAll(
          Size(46, windowsTitleBarHeight),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          final highlighted = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed);
          if (destructive && highlighted) return Colors.white;
          return AppTheme.textSecondary;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          final highlighted = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed);
          if (!highlighted) return Colors.transparent;
          return destructive ? AppTheme.error : AppTheme.cardHover;
        }),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      icon: Icon(icon),
    );
  }
}

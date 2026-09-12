import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;

/// One background-only GPU texture per page; never captures glass recursively.
class SsrvpnGlassCapture extends StatefulWidget {
  const SsrvpnGlassCapture({super.key, required this.child});
  final Widget child;
  @override
  State<SsrvpnGlassCapture> createState() => _SsrvpnGlassCaptureState();
}

class _SsrvpnGlassCaptureState extends State<SsrvpnGlassCapture>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _capture = ValueNotifier<SsrvpnGlassFrame?>(null);
  late final Ticker _ticker;
  GlobalKey? _key;
  bool _queued = false;
  bool _active = true;
  bool _enabled = false;
  final _retired = <ui.Image>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((_) => _scheduleCapture());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _key = glass.LiquidGlassScope.of(context);
    _enabled = ui.ImageFilter.isShaderFilterSupported &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.highContrastOf(context) &&
        (glass.GlassAdaptiveScopeData.maybeOf(context)?.effectiveQuality ??
                glass.GlassQuality.premium) ==
            glass.GlassQuality.premium;
    _updateTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _updateTicker();
  }

  void _updateTicker() {
    if (_enabled && _active) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  void _scheduleCapture() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted || !_enabled || !_active) return;
      final boundary = _key?.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary ||
          !boundary.attached ||
          !boundary.hasSize ||
          boundary.size.isEmpty) {
        return;
      }
      // Post-paint capture avoids reading an unpainted/stale retained layer.
      // Keep the previous texture alive until its consuming frame has painted.
      for (final image in _retired) {
        image.dispose();
      }
      _retired.clear();
      final previous = _capture.value;
      final image =
          boundary.toImageSync(pixelRatio: View.of(context).devicePixelRatio);
      _capture.value =
          SsrvpnGlassFrame(image, boundary.localToGlobal(Offset.zero));
      if (previous != null) _retired.add(previous.image);
    });
  }

  @override
  Widget build(BuildContext context) =>
      _CapturedGlass(notifier: _capture, child: widget.child);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _capture.value?.image.dispose();
    for (final image in _retired) {
      image.dispose();
    }
    _capture.dispose();
    super.dispose();
  }
}

class SsrvpnGlassFrame {
  const SsrvpnGlassFrame(this.image, this.origin);
  final ui.Image image;
  final Offset origin;
  static SsrvpnGlassFrame? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_CapturedGlass>()
      ?.notifier
      ?.value;
  static bool hasScope(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_CapturedGlass>() != null;
}

class _CapturedGlass
    extends InheritedNotifier<ValueNotifier<SsrvpnGlassFrame?>> {
  const _CapturedGlass({required super.notifier, required super.child});
}

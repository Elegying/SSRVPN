import 'ssrvpn_liquid_glass.dart' show ssrvpnGlassQuality;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;

/// One background-only GPU texture per page; never captures glass recursively.
class SsrvpnGlassCapture extends StatefulWidget {
  const SsrvpnGlassCapture(
      {super.key,
      required this.child,
      @visibleForTesting this.captureSupported});
  final bool? captureSupported;
  final Widget child;
  @override
  State<SsrvpnGlassCapture> createState() => _SsrvpnGlassCaptureState();
}

class _SsrvpnGlassCaptureState extends State<SsrvpnGlassCapture>
    with WidgetsBindingObserver {
  final _capture = ValueNotifier<SsrvpnGlassFrame?>(null);
  GlobalKey? _key;
  ModalRoute<dynamic>? _route;
  bool _queued = false;
  bool _releaseQueued = false;
  bool _enabled = false;
  int _capturedRevision = -1;
  double? _capturedDpr;
  final _retired = <ui.Image>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _key = glass.LiquidGlassScope.of(context);
    _enabled =
        (widget.captureSupported ?? ui.ImageFilter.isShaderFilterSupported) &&
            TickerMode.valuesOf(context).enabled &&
            !MediaQuery.highContrastOf(context) &&
            ssrvpnGlassQuality(context) == glass.GlassQuality.premium;
    final route = ModalRoute.of(context);
    if (_route != route) {
      _listenToRoute(false);
      _route = route;
      _listenToRoute(true);
    }
    if (_enabled) {
      _scheduleCapture();
    } else {
      _releaseUnusedCapture();
    }
  }

  void _releaseUnusedCapture() {
    if (_releaseQueued || _capture.value == null) return;
    _releaseQueued = true;
    // Dependencies may change during build. Publish only after the tree has
    // switched materials, and retain the image until consumers paint without it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _releaseQueued = false;
      if (!mounted || _enabled) return;
      final previous = _capture.value;
      _capture.value = null;
      if (previous != null) _retire(previous.image);
    });
  }

  void _retire(ui.Image image) {
    _retired.add(image);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_retired.remove(image)) return;
      image.dispose();
    });
  }

  void _listenToRoute(bool add) {
    for (final animation in [_route?.animation, _route?.secondaryAnimation]) {
      if (add) {
        animation?.addListener(_scheduleCapture);
      } else {
        animation?.removeListener(_scheduleCapture);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleCapture();
  }

  void _scheduleCapture() {
    // Minimal/high-contrast surfaces do not consume a texture. Avoid queuing
    // a no-op callback on every wallpaper paint; re-enabling or resuming calls
    // this method again and captures the latest background revision.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_queued ||
        !mounted ||
        !_enabled ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          !_enabled ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
        return;
      }
      final boundary = _key?.currentContext?.findRenderObject();
      if (boundary is! _RenderCaptureBackground ||
          !boundary.attached ||
          !boundary.readyToCapture ||
          !boundary.hasSize ||
          boundary.size.isEmpty) {
        return;
      }
      final dpr = View.of(context).devicePixelRatio;
      final previous = _capture.value;
      final origin = boundary.localToGlobal(Offset.zero);
      // Moving a page only changes the sampling origin; its texture is reusable.
      // A paused wallpaper produces no paint events and no capture loop at all.
      final repaint = previous == null ||
          _capturedRevision != boundary.revision ||
          _capturedDpr != dpr;
      if (!repaint && previous.origin == origin) return;
      final image =
          repaint ? boundary.toImageSync(pixelRatio: dpr) : previous.image;
      _capturedRevision = boundary.revision;
      _capturedDpr = dpr;
      _capture.value = SsrvpnGlassFrame(image, origin);
      if (previous != null && !identical(previous.image, image)) {
        _retire(previous.image);
      }
    }, debugLabel: 'SSRVPN glass capture');
  }

  @override
  Widget build(BuildContext context) => _CapturedGlass(
      frames: _capture,
      onBackgroundPaint: _scheduleCapture,
      child: widget.child);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _listenToRoute(false);
    _capture.value?.image.dispose();
    for (final image in _retired) {
      image.dispose();
    }
    _retired.clear();
    _capture.dispose();
    super.dispose();
  }
}

/// Paint-driven source: source changes schedule one capture after paint, while
/// foreground animation/scrolling cannot recursively capture or dirty it.
class SsrvpnGlassBackgroundSource extends StatelessWidget {
  const SsrvpnGlassBackgroundSource({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => _CaptureBackground(
      key: glass.LiquidGlassScope.of(context),
      onPaint: context
          .dependOnInheritedWidgetOfExactType<_CapturedGlass>()!
          .onBackgroundPaint,
      child: child);
}

class _CaptureBackground extends SingleChildRenderObjectWidget {
  const _CaptureBackground(
      {super.key, required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCaptureBackground(onPaint);
  @override
  void updateRenderObject(
      BuildContext context, _RenderCaptureBackground renderObject) {
    renderObject.onPaint = onPaint;
  }
}

class _RenderCaptureBackground extends RenderRepaintBoundary {
  _RenderCaptureBackground(this.onPaint);
  VoidCallback onPaint;
  int revision = 0;
  bool readyToCapture = false;
  @override
  void markNeedsPaint() {
    readyToCapture = false;
    super.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    revision++;
    readyToCapture = true;
    onPaint();
  }
}

class SsrvpnGlassFrame {
  const SsrvpnGlassFrame(this.image, this.origin);
  final ui.Image image;
  final Offset origin;
  static ValueListenable<SsrvpnGlassFrame?>? listenableOf(
          BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CapturedGlass>()?.frames;
}

class _CapturedGlass extends InheritedWidget {
  const _CapturedGlass(
      {required this.frames,
      required this.onBackgroundPaint,
      required super.child});
  final ValueNotifier<SsrvpnGlassFrame?> frames;
  final VoidCallback onBackgroundPaint;
  @override
  bool updateShouldNotify(_CapturedGlass oldWidget) =>
      oldWidget.frames != frames;
}

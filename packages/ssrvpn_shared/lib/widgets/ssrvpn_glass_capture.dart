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

  /// Frame timestamp of the last rasterizing capture. Null means "raster as soon
  /// as possible" and is set on first capture, re-enable, and resume so those
  /// discrete events are never throttled.
  Duration? _lastRasterFrame;

  /// Upper bound on how often a continuously repainting source is re-rasterized.
  /// The drift moves only a few device pixels per window, which stays invisible
  /// behind the glass blur while cutting the raster cost by roughly 6x at 60Hz.
  ///
  /// Invariant behind that claim: the capture source only drifts by sub-percent
  /// amounts between two windows. The wallpaper traverses 11% of its width over
  /// an 18s cosine cycle, so one 100ms window advances it by at most ~0.2% of
  /// the surface (worst case ~2 device pixels on a 3x display), which the 1.16x
  /// overscan and the glass blur hide. Raising this interval, or routing real
  /// content (video, live data) through the capture source, would turn that
  /// staleness into a visible jump instead of a sub-pixel drift.
  static const _minRasterInterval = Duration(milliseconds: 100);
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
      // First build, re-enable, or a media/contrast switch is a discrete event,
      // so the next capture must not be suppressed by the throttle window.
      _lastRasterFrame = null;
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
    if (state == AppLifecycleState.resumed) {
      // Return with fresh pixels rather than a frame held across the pause.
      _lastRasterFrame = null;
      _scheduleCapture();
    }
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
      // A pixel-ratio change is about sharpness, never motion: always raster it.
      final dprChanged = _capturedDpr != dpr;
      // Content changes only when the source repaints. A paused or static
      // wallpaper produces no paint events and therefore no capture loop.
      final contentChanged =
          previous == null || _capturedRevision != boundary.revision;
      // A layout change is the one case where the held texture is *wrong*
      // rather than merely stale: it is still the old size, so glass would
      // sample a background short by (elapsed x drag speed) until the next
      // raster. Measured at 21 device pixels on a 3.0 dpr resize. Compare
      // against the size `toImageSync` actually produces, which is
      // ceil(size * dpr).
      final expectedWidth = (boundary.size.width * dpr).ceil();
      final expectedHeight = (boundary.size.height * dpr).ceil();
      final sizeChanged = previous != null &&
          (previous.image.width != expectedWidth ||
              previous.image.height != expectedHeight);
      if (!contentChanged && !dprChanged && !sizeChanged) {
        // Moving a page only changes the sampling origin; its texture stays
        // reusable and republishing it costs no rasterization.
        if (previous.origin == origin) return;
        _capture.value = SsrvpnGlassFrame(previous.image, origin);
        return;
      }
      // Rasterizing is the expensive step: an offscreen full-surface pass plus a
      // fresh full-surface texture. A drifting wallpaper would pay it on every
      // frame, so cap it well below the frame rate. The skipped frames move the
      // background by at most a few device pixels, which the glass blur hides.
      // A resize is exempt: it already repaints every frame, so the cap saves
      // nothing there while introducing the size error described above.
      if (!dprChanged &&
          !sizeChanged &&
          previous != null &&
          _lastRasterFrame != null &&
          WidgetsBinding.instance.currentFrameTimeStamp - _lastRasterFrame! <
              _minRasterInterval) {
        // Inside the window: keep the last texture but still track the page so
        // glass never drifts off its origin. The next repaint after the window
        // refreshes the pixels, so no trailing timer is needed.
        if (previous.origin != origin) {
          _capture.value = SsrvpnGlassFrame(previous.image, origin);
        }
        return;
      }
      _lastRasterFrame = WidgetsBinding.instance.currentFrameTimeStamp;
      final image = boundary.toImageSync(pixelRatio: dpr);
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

  /// Popup routes are siblings of the page, so they cannot inherit its wallpaper
  /// capture. Share the source without capturing the foreground cards again.
  static Widget share({
    required ValueListenable<SsrvpnGlassFrame?>? frames,
    required Widget child,
  }) =>
      frames == null
          ? child
          : _CapturedGlass(
              frames: frames, onBackgroundPaint: () {}, child: child);
}

class _CapturedGlass extends InheritedWidget {
  const _CapturedGlass(
      {required this.frames,
      required this.onBackgroundPaint,
      required super.child});
  final ValueListenable<SsrvpnGlassFrame?> frames;
  final VoidCallback onBackgroundPaint;
  @override
  bool updateShouldNotify(_CapturedGlass oldWidget) =>
      oldWidget.frames != frames;
}

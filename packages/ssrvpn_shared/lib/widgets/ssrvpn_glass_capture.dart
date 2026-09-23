import 'ssrvpn_liquid_glass.dart' show ssrvpnGlassQuality;
import 'dart:async';
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

  /// Number of consecutive frames the first capture has been retried while the
  /// boundary was not yet paintable. Bounded so a boundary that never becomes
  /// paintable cannot spin the scheduler forever.
  int _startupRetry = 0;
  static const _maxStartupRetry = 8;

  /// Deferred re-raster scheduled when a content change landed inside the
  /// throttle window. A drifting wallpaper repaints every frame so its next
  /// paint re-runs this method; a *still* wallpaper that just finished
  /// decoding its image (placeholder → real pixels) repaints once and then
  /// never again, so without this trailing timer the glass would hold the
  /// placeholder forever.
  Timer? _throttledRefresh;

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
    }
    // Every transition is a chance to (re)install the texture, including one
    // that arrives while the surface is merely unfocused. A pause still
    // declines in `_scheduleCapture`, so this cannot rasterize in the
    // background.
    _scheduleCapture();
  }

  /// Whether a capture is allowed right now.
  ///
  /// A definite `paused`/`detached`/`hidden` is a real reason to hold off.
  /// `hidden` is the engine's report for a minimized desktop window (see
  /// `AppLifecycleState.hidden`), so rasterizing it would waste a capture on a
  /// surface the user cannot see. `inactive` is not: on desktop it is an
  /// ordinary focus change while the window stays visible, and the Windows
  /// runner never notifies Flutter from `WM_ACTIVATE`, so a freshly launched
  /// window can sit in `inactive` (or with no reported state at all) until
  /// Flutter's own focus handling runs.
  bool get _mayCapture {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null ||
        (lifecycle != AppLifecycleState.paused &&
            lifecycle != AppLifecycleState.detached &&
            lifecycle != AppLifecycleState.hidden);
  }

  void _scheduleCapture() {
    // Minimal/high-contrast surfaces do not consume a texture. Avoid queuing
    // a no-op callback on every wallpaper paint; re-enabling or resuming calls
    // this method again and captures the latest background revision.
    if (_queued || !mounted || !_enabled || !_mayCapture) {
      return;
    }
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted || !_enabled || !_mayCapture) {
        return;
      }
      final boundary = _key?.currentContext?.findRenderObject();
      if (boundary is! _RenderCaptureBackground ||
          !boundary.attached ||
          !boundary.readyToCapture ||
          !boundary.hasSize ||
          boundary.size.isEmpty) {
        // Not paintable yet. Normally this is not a dead end: the source
        // repaints on its own cadence and calls `onBackgroundPaint` again, and
        // every lifecycle transition calls this method. But on a cold start
        // with a *still* wallpaper, the source paints exactly once before this
        // callback runs (its paint is what queued us), so if that first paint
        // happened while the boundary was not yet sized — e.g. the asset is
        // still decoding — there is never a second paint, no lifecycle change,
        // and the glass stays blank until the user toggles a quality tier or
        // pushes a route. Retry a bounded number of frames to survive that
        // cold-start window, then give up so a genuinely dead boundary cannot
        // spin the scheduler forever.
        if (_capture.value == null && _startupRetry < _maxStartupRetry) {
          _startupRetry++;
          _scheduleCapture();
        }
        return;
      }
      _startupRetry = 0;
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
        // glass never drifts off its origin. A drifting wallpaper repaints on
        // the next frame and refreshes the pixels then. A still wallpaper does
        // not — its one and only repaint (e.g. the image finishing decode)
        // already happened, so schedule one deferred re-raster at the window
        // edge instead of dropping the change entirely.
        if (previous.origin != origin) {
          _capture.value = SsrvpnGlassFrame(previous.image, origin);
        }
        _scheduleThrottledRefresh();
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
    // A timer, lifecycle event, or startup retry can arrive with no frame in
    // flight. Post-frame callbacks alone never wake an idle engine. This is a
    // no-op during paint, so ordinary source paints do not create a frame loop.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Arms a single trailing re-raster at the edge of the throttle window.
  ///
  /// Only one is ever pending; a drifting wallpaper re-arms it each frame, so
  /// it still collapses to roughly one extra capture per window (the throttle
  /// guarantee). A still wallpaper arms it exactly once and gets exactly the
  /// refresh its lone repaint needs.
  void _scheduleThrottledRefresh() {
    if (_throttledRefresh != null) return;
    final elapsed = WidgetsBinding.instance.currentFrameTimeStamp -
        (_lastRasterFrame ?? WidgetsBinding.instance.currentFrameTimeStamp);
    final wait = _minRasterInterval - elapsed;
    _throttledRefresh = Timer(wait.isNegative ? Duration.zero : wait, () {
      _throttledRefresh = null;
      _scheduleCapture();
    });
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
    _throttledRefresh?.cancel();
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

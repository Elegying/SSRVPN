import '../models/app_settings.dart';
import 'ssrvpn_appearance.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'ssrvpn_glass_capture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'ssrvpn_frame_diagnostics.dart';
import 'ssrvpn_frame_pacing.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;

/// Shared, bounded-cost material for the three clients.
class SsrvpnLiquidSurface extends StatelessWidget {
  const SsrvpnLiquidSurface(
      {super.key,
      required this.child,
      this.radius = 16,
      this.padding = EdgeInsets.zero,
      this.dense = false,
      this.tint,
      this.borderColor,
      this.circular = false});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool dense;
  final Color? tint;
  final Color? borderColor;
  final bool circular;

  static const settings = glass.LiquidGlassSettings(
    glassColor: Color(0x283B426A),
    blur: 7,
    thickness: 30,
    lightIntensity: .85,
    fresnelStrength: .6,
    saturation: 1.25,
  );

  /// Standard uses a 2D renderer and does not normalize premium parameters.
  /// Match the library's premium-to-lightweight calibration explicitly.
  static glass.LiquidGlassSettings settingsFor(BuildContext context) =>
      ssrvpnGlassQuality(context) == glass.GlassQuality.standard
          ? settings.copyWith(thickness: 12, lightIntensity: .51)
          : settings;

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final content = Padding(padding: padding, child: child);
    if (highContrast || ssrvpnGlassDisabled(context)) {
      return DecoratedBox(
          decoration: BoxDecoration(
              color: dark ? const Color(0xFF111827) : Colors.white,
              shape: circular ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: circular ? null : BorderRadius.circular(radius),
              border:
                  Border.all(color: Theme.of(context).colorScheme.onSurface)),
          child: content);
    }
    final quality = ssrvpnGlassQuality(context);
    if (quality == glass.GlassQuality.minimal) {
      // Old mobile GPUs can spend >80 ms on a stack of native backdrop blurs.
      // The low tier keeps translucent color and edge definition, with no
      // offscreen filter, custom shader, or per-card capture.
      return DecoratedBox(
        decoration: BoxDecoration(
          color: tint?.withValues(alpha: .18) ??
              (dark ? const Color(0x50303C60) : const Color(0xB8FFFFFF)),
          shape: circular ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circular ? null : BorderRadius.circular(radius),
          border: Border.all(
              color: borderColor ?? Colors.white.withValues(alpha: .18)),
        ),
        child: content,
      );
    }
    final frames = SsrvpnGlassFrame.listenableOf(context);
    final useCapture = quality == glass.GlassQuality.premium &&
        ui.ImageFilter.isShaderFilterSupported &&
        frames != null;
    final surfaceSettings = settingsFor(context).copyWith(
        blur: dense ? 5 : 7,
        glassColor: tint?.withValues(alpha: .18) ??
            (dark ? const Color(0x30303C60) : const Color(0x88FFFFFF)));
    final surface = glass.GlassContainer(
      shape: circular
          ? const glass.LiquidOval()
          : glass.LiquidRoundedSuperellipse(borderRadius: radius),
      quality: quality,
      useOwnLayer: !useCapture,
      clipBehavior: Clip.antiAlias,
      settings: surfaceSettings,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: circular ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circular ? null : BorderRadius.circular(radius),
          border: Border.all(
              color: borderColor ?? Colors.white.withValues(alpha: .18)),
        ),
        child: content,
      ),
    );
    if (!useCapture) return surface;
    // Rebuild only the sampling layer. Geometry, layout, forms and text are
    // retained when the wallpaper changes; optical settings remain identical.
    return ValueListenableBuilder<SsrvpnGlassFrame?>(
      valueListenable: frames,
      child: surface,
      builder: (context, captured, child) {
        return glass.LiquidGlassLayer(
            settings: surfaceSettings,
            captureOnly: true,
            captureImage: captured?.image,
            captureOriginInScreenSpace: captured?.origin ?? Offset.zero,
            // A new sampling layer also needs its own geometry group. Otherwise
            // nested cards register with an outer dialog's group and are painted
            // above the intervening scroll viewport, bypassing its clipping.
            child: glass.LiquidGlassBlendGroup(blend: 0, child: child!));
      },
    );
  }
}

/// Preload platform-supported shaders; shader failure cannot block launch.
Future<void> initializeSsrvpnLiquidGlass() async {
  try {
    await glass.LiquidGlassWidgets.initialize(
      warmUpMode: glass.GlassWarmUpMode.auto,
      enablePerformanceMonitor: false,
    );
  } catch (error) {
    debugPrint('Liquid glass preload unavailable; using fallback: $error');
  }
}

/// Keep the device tier stable; frame spikes never switch optical materials.
bool ssrvpnGlassDisabled(BuildContext context) =>
    SsrvpnAppearance.maybeOf(context)?.level == GlassEffectLevel.none;

glass.GlassQuality ssrvpnGlassQuality(BuildContext context) =>
    switch (SsrvpnAppearance.maybeOf(context)?.level) {
      GlassEffectLevel.none ||
      GlassEffectLevel.low =>
        glass.GlassQuality.minimal,
      GlassEffectLevel.medium => glass.GlassQuality.standard,
      GlassEffectLevel.high => glass.GlassQuality.premium,
      null => glass.GlassAdaptiveScopeData.maybeOf(context)?.effectiveQuality ??
          glass.GlassQuality.premium,
    };

bool ssrvpnUsesLowEffects(BuildContext context) =>
    ssrvpnGlassQuality(context) == glass.GlassQuality.minimal;

int ssrvpnFrameBudget(double refreshRate) =>
    (1000 / (refreshRate.isFinite && refreshRate > 0 ? refreshRate : 60))
        .floor()
        .clamp(4, 33);

Widget wrapSsrvpnLiquidGlass(Widget child) => _AdaptiveGlassHost(child: child);

class _AdaptiveGlassHost extends StatefulWidget {
  const _AdaptiveGlassHost({required this.child});
  final Widget child;
  @override
  State<_AdaptiveGlassHost> createState() => _AdaptiveGlassHostState();
}

class _AdaptiveGlassHostState extends State<_AdaptiveGlassHost>
    with WidgetsBindingObserver {
  final _diagnostics = SsrvpnFrameDiagnostics();
  Timer? _refreshPoll;
  double? _nativeRefreshRate;
  bool _readingRefreshRate = false;
  bool _refreshRateSupported = true;
  bool _lowPerformance = false;
  bool _capabilityRead = false;
  SsrvpnFramePacing? _pacing;
  static const _display = MethodChannel('com.ssrvpn/display');

  Future<void> _readRefreshRate() async {
    if (_readingRefreshRate ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _readingRefreshRate = true;
    try {
      if (!_capabilityRead) {
        var low = false;
        try {
          low = await _display.invokeMethod<bool>('lowPerformance') ?? false;
        } on MissingPluginException {
          // Older native hosts may still support refreshRate independently.
        } on PlatformException {
          // Unknown hardware retains the normal tier.
        }
        if (mounted) {
          setState(() => _lowPerformance = low);
          if (low) {
            _pacing =
                SsrvpnFramePacing(WidgetsBinding.instance.platformDispatcher)
                  ..install();
          }
        }
        _capabilityRead = true;
        if (SsrvpnFrameDiagnostics.enabled) {
          debugPrint('SSRVPN_DEVICE lowPerformance=$low '
              'frameCap=${_pacing?.isInstalled == true ? 60 : "system"}');
        }
      }
      if (!_refreshRateSupported) return;
      final rate = await _display.invokeMethod<double>('refreshRate');
      if (mounted &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          rate != null &&
          rate.isFinite &&
          rate > 0 &&
          (_nativeRefreshRate == null ||
              (rate - _nativeRefreshRate!).abs() > .5)) {
        setState(() => _nativeRefreshRate = rate);
      }
    } on PlatformException {
      // Optional hint; rendering must remain available.
    } on MissingPluginException {
      // An absent native method cannot appear later in this engine session.
      // Use Flutter's display information without repeatedly invoking it.
      _refreshRateSupported = false;
      _refreshPoll?.cancel();
      _refreshPoll = null;
    } finally {
      _readingRefreshRate = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateRefreshPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _updateRefreshPolling();

  void _updateRefreshPolling() {
    // Do not combine pre-background frames with a later foreground session.
    _diagnostics.stop();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _diagnostics.start();
    }
    _refreshPoll?.cancel();
    _refreshPoll = null;
    if (!kIsWeb &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _readRefreshRate();
      if (_refreshRateSupported) {
        _refreshPoll = Timer.periodic(
            const Duration(seconds: 2), (_) => _readRefreshRate());
      }
    }
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshPoll?.cancel();
    _diagnostics.stop();
    _pacing?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _diagnostics.refreshRate =
        _nativeRefreshRate ?? View.maybeOf(context)?.display.refreshRate ?? 60;
    _diagnostics.targetFps = _lowPerformance ? 60 : null;
    final budget =
        ssrvpnFrameBudget(_lowPerformance ? 60 : _diagnostics.refreshRate);
    final quality = _lowPerformance
        ? glass.GlassQuality.minimal
        : glass.GlassQuality.premium;
    return glass.LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      adaptiveConfig: glass.GlassAdaptiveScopeConfig(
        minQuality: quality,
        maxQuality: quality,
        initialQuality: quality,
        targetFrameMs: budget,
        onQualityChanged: (_, quality) {
          if (SsrvpnFrameDiagnostics.enabled) {
            debugPrint('SSRVPN_GLASS quality=${quality.name} budgetMs=$budget');
          }
        },
        warmupPremiumThresholdMs: budget * .75,
        warmupStandardThresholdMs: budget.toDouble(),
      ),
      brightnessResolver: Theme.maybeBrightnessOf,
      child: widget.child,
    );
  }
}

/// Labels and help live outside the clipped input material at every text scale.
class SsrvpnLiquidField extends StatelessWidget {
  const SsrvpnLiquidField(
      {super.key, required this.child, this.label, this.helperText});
  final Widget child;
  final String? label;
  final String? helperText;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = OutlineInputBorder(
        borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: ExcludeSemantics(
                child: Text(label!,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          ),
        Semantics(
            label: label,
            child: SsrvpnLiquidSurface(
              radius: 14,
              dense: true,
              child: Theme(
                data: theme.copyWith(
                    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                  filled: true,
                  fillColor: Colors.transparent,
                  border: outline,
                  enabledBorder: outline,
                  disabledBorder: outline,
                  errorMaxLines: 3,
                )),
                child: child,
              ),
            )),
        if (helperText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(helperText!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                softWrap: true),
          ),
      ],
    );
  }
}

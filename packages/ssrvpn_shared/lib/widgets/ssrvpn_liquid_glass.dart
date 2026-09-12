import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'ssrvpn_frame_diagnostics.dart';
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

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final content = Padding(padding: padding, child: child);
    if (highContrast) {
      return DecoratedBox(
          decoration: BoxDecoration(
              color: dark ? const Color(0xFF111827) : Colors.white,
              shape: circular ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: circular ? null : BorderRadius.circular(radius),
              border:
                  Border.all(color: Theme.of(context).colorScheme.onSurface)),
          child: content);
    }
    return glass.GlassContainer(
      shape: circular
          ? const glass.LiquidOval()
          : glass.LiquidRoundedSuperellipse(borderRadius: radius),
      quality: ssrvpnGlassQuality(context, scrollable: dense),
      useOwnLayer: true,
      clipBehavior: Clip.antiAlias,
      settings: settings.copyWith(
          blur: dense ? 5 : 7,
          glassColor: tint?.withValues(alpha: .18) ??
              (dark ? const Color(0x30303C60) : const Color(0x88FFFFFF))),
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

/// Apply the adaptive ceiling consistently and keep texture-capture premium
/// out of scrollable content, including controls nested in sliver headers.
glass.GlassQuality ssrvpnGlassQuality(BuildContext context,
    {bool scrollable = false}) {
  final ceiling =
      glass.GlassAdaptiveScopeData.maybeOf(context)?.effectiveQuality ??
          glass.GlassQuality.premium;
  if (ceiling == glass.GlassQuality.minimal) return ceiling;
  if (scrollable ||
      Scrollable.maybeOf(context) != null ||
      ModalRoute.of(context) is PopupRoute) {
    return glass.GlassQuality.standard;
  }
  return ceiling;
}

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
  static const _display = MethodChannel('com.ssrvpn/display');

  Future<void> _readRefreshRate() async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    try {
      final rate = await _display.invokeMethod<double>('refreshRate');
      if (mounted &&
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
      // Desktop and old native hosts use Flutter display information.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _diagnostics.start();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _readRefreshRate();
      _refreshPoll =
          Timer.periodic(const Duration(seconds: 2), (_) => _readRefreshRate());
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _diagnostics.refreshRate =
        _nativeRefreshRate ?? View.maybeOf(context)?.display.refreshRate ?? 60;
    final budget = ssrvpnFrameBudget(_diagnostics.refreshRate);
    return glass.LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      adaptiveConfig: glass.GlassAdaptiveScopeConfig(
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

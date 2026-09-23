import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Desktop inactivity means loss of keyboard focus, not a hidden window.
/// Mobile platforms retain their existing foreground-only polling policy.
bool statisticsViewIsVisible(AppLifecycleState? state) {
  if (state == null || state == AppLifecycleState.resumed) return true;
  return state == AppLifecycleState.inactive &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);
}

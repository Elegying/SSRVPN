import 'package:flutter/services.dart';

enum WindowsTunElevationRequestResult {
  launched,
  cancelled,
  standardUser,
  failed,
}

/// Bridges the Flutter process to the native runner for UAC elevation.
///
/// The current process is never elevated in place. The runner starts the
/// canonical outer launcher with the `runas` shell verb and a one-shot resume
/// flag. The elevated launcher then waits for the current guarded process tree
/// to finish its normal shutdown before starting the replacement instance.
class WindowsTunElevationService {
  WindowsTunElevationService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.ssrvpn.windows/tun_elevation';
  final MethodChannel _channel;

  Future<bool?> queryIsElevated() async {
    try {
      final state = await _channel.invokeMethod<String>('queryElevationState');
      return switch (state) {
        'elevated' => true,
        'limited' || 'standard' => false,
        _ => null,
      };
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<WindowsTunElevationRequestResult> requestRelaunch() async {
    try {
      final result = await _channel.invokeMethod<String>(
        'requestTunElevationRelaunch',
      );
      return switch (result) {
        'launched' => WindowsTunElevationRequestResult.launched,
        'cancelled' => WindowsTunElevationRequestResult.cancelled,
        'standardUser' => WindowsTunElevationRequestResult.standardUser,
        _ => WindowsTunElevationRequestResult.failed,
      };
    } on MissingPluginException {
      return WindowsTunElevationRequestResult.failed;
    } on PlatformException {
      return WindowsTunElevationRequestResult.failed;
    }
  }
}

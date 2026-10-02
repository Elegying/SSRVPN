import 'dart:async';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';

/// Windows camera access without Android/iOS camera plugins or audio permissions.
class SsrvpnWindowsQrCamera {
  SsrvpnWindowsQrCamera({CameraPlatform? platform})
      : _platform = platform ?? CameraPlatform.instance;
  final CameraPlatform _platform;
  int? _id;
  bool _disposed = false;
  CameraInitializedEvent? _info;
  StreamSubscription<CameraInitializedEvent>? _events;
  Completer<CameraInitializedEvent>? _ready;
  bool get isInitialized => !_disposed && _info != null;
  Future<void> initialize() async {
    final cameras = await _platform.availableCameras();
    if (_disposed) return;
    if (cameras.isEmpty) throw StateError('no camera');
    final id = await _platform.createCameraWithSettings(
        cameras.first,
        const MediaSettings(
            resolutionPreset: ResolutionPreset.medium, enableAudio: false));
    if (_disposed) {
      try {
        await _platform.dispose(id);
      } catch (_) {}
      return;
    }
    _id = id;
    final ready = Completer<CameraInitializedEvent>();
    _ready = ready;
    _events = _platform.onCameraInitialized(id).listen((event) {
      if (!ready.isCompleted) ready.complete(event);
    }, onError: (Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    });
    // Attach an error handler before initialization can fail or the timer expires.
    final initialized = ready.future.timeout(const Duration(seconds: 10));
    initialized.ignore();
    try {
      await _platform.initializeCamera(id).timeout(const Duration(seconds: 10));
      final info = await initialized;
      if (!_disposed &&
          info.previewWidth.isFinite &&
          info.previewHeight.isFinite &&
          info.previewWidth > 0 &&
          info.previewHeight > 0) {
        _info = info;
      }
      if (!_disposed && _info == null) {
        throw StateError('invalid camera preview');
      }
    } finally {
      await _events?.cancel();
      _events = null;
    }
  }

  Widget preview() {
    final info = _info;
    if (!isInitialized || _id == null || info == null) {
      return const SizedBox.shrink();
    }
    return Center(
        child: AspectRatio(
            aspectRatio: info.previewWidth / info.previewHeight,
            child: _platform.buildPreview(_id!)));
  }

  Future<XFile> takePicture() {
    if (!isInitialized || _id == null) throw StateError('camera unavailable');
    return _platform.takePicture(_id!);
  }

  Future<void> dispose() async {
    _disposed = true;
    _info = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('camera closed'));
    }
    await _events?.cancel();
    _events = null;
    final id = _id;
    _id = null;
    if (id != null) {
      try {
        await _platform.dispose(id);
      } catch (_) {}
    }
  }
}

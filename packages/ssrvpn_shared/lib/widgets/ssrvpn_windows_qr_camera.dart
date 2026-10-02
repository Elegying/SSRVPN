import 'dart:async';
import 'dart:io';
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
  static const _timeout = Duration(seconds: 10);
  bool get isInitialized => !_disposed && _info != null;
  Future<void> initialize() async {
    final cameras = await _platform.availableCameras().timeout(_timeout);
    if (_disposed) return;
    if (cameras.isEmpty) throw StateError('no camera');
    final created = _platform
        .createCameraWithSettings(
            cameras.first,
            const MediaSettings(
                resolutionPreset: ResolutionPreset.medium, enableAudio: false))
        .then<int?>((id) async {
      if (_disposed) {
        await _release(id);
        return null;
      }
      _id = id;
      return id;
    });
    final id = await created.timeout(_timeout, onTimeout: () {
      _disposed = true;
      throw TimeoutException('camera creation timed out');
    });
    if (_disposed || id == null) return;
    final ready = Completer<CameraInitializedEvent>();
    _ready = ready;
    _events = _platform.onCameraInitialized(id).listen((event) {
      if (!ready.isCompleted) ready.complete(event);
    }, onError: (Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    });
    // Attach an error handler before initialization can fail or the timer expires.
    final initialized = ready.future.timeout(_timeout);
    initialized.ignore();
    try {
      await _platform.initializeCamera(id).timeout(_timeout);
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
    var expired = false;
    final captured = _platform.takePicture(_id!).then((file) async {
      if (expired) {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
      return file;
    });
    return captured.timeout(_timeout, onTimeout: () {
      expired = true;
      throw TimeoutException('camera capture timed out');
    });
  }

  Future<void> _release(int id) async {
    try {
      await _platform.dispose(id).timeout(_timeout);
    } catch (_) {}
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
    if (id != null) await _release(id);
  }
}

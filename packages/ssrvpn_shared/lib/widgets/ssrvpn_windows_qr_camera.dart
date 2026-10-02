import 'dart:async';
import 'dart:io';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';

/// Windows camera access without Android/iOS camera plugins or audio permissions.
class SsrvpnWindowsQrCamera {
  SsrvpnWindowsQrCamera({CameraPlatform? platform})
      : _platform = platform ?? CameraPlatform.instance;
  final CameraPlatform _platform;
  final _pending = <void Function()>{};
  int? _id;
  bool _disposed = false;
  CameraInitializedEvent? _info;
  StreamSubscription<CameraInitializedEvent>? _events;
  Completer<CameraInitializedEvent>? _ready;
  static const _timeout = Duration(seconds: 10);
  bool get isInitialized => !_disposed && _info != null;
  Future<T> _wait<T>(Future<T> operation, {void Function()? onTimeout}) {
    final result = Completer<T>();
    late Timer timer;
    void cancel() {
      if (!result.isCompleted) {
        result.completeError(StateError('camera closed'));
      }
    }

    timer = Timer(_timeout, () {
      onTimeout?.call();
      if (!result.isCompleted) {
        result.completeError(TimeoutException('camera operation timed out'));
      }
    });
    _pending.add(cancel);
    operation.then((value) {
      if (!result.isCompleted) result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    });
    if (_disposed) cancel();
    return result.future.whenComplete(() {
      timer.cancel();
      _pending.remove(cancel);
    });
  }

  Future<void> initialize() async {
    final cameras = await _wait(_platform.availableCameras());
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
    final id = await _wait(created, onTimeout: () {
      _disposed = true;
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
    final initialized = _wait(ready.future);
    initialized.ignore();
    try {
      await _wait(_platform.initializeCamera(id));
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
      await _cancelEvents();
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
      if (expired || _disposed) {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
      return file;
    });
    return _wait(captured).onError((error, stack) {
      expired = true;
      Error.throwWithStackTrace(error!, stack);
    });
  }

  Future<void> _release(int id) async {
    try {
      await _platform.dispose(id).timeout(_timeout);
    } catch (_) {}
  }

  Future<void> _cancelEvents() async {
    final events = _events;
    _events = null;
    try {
      await events?.cancel().timeout(_timeout);
    } catch (_) {
      // Event-channel cleanup must never prevent releasing the camera device.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final cancel in _pending.toList()) {
      cancel();
    }
    _info = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('camera closed'));
    }
    await _cancelEvents();
    final id = _id;
    _id = null;
    if (id != null) await _release(id);
  }
}

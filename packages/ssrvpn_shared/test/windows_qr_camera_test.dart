import 'dart:async';
import 'dart:typed_data';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_windows_qr_camera.dart';

class FakeCamera extends CameraPlatform {
  final events = StreamController<CameraInitializedEvent>.broadcast();
  final disposed = <int>[];
  MediaSettings? settings;
  Completer<int>? pendingCreate;
  bool deny = false;
  @override
  Future<List<CameraDescription>> availableCameras() async => [
        const CameraDescription(
            name: 'test',
            lensDirection: CameraLensDirection.front,
            sensorOrientation: 0)
      ];
  @override
  Future<int> createCameraWithSettings(
      CameraDescription camera, MediaSettings settings) async {
    this.settings = settings;
    return pendingCreate?.future ?? 7;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int id) => events.stream;
  @override
  Future<void> initializeCamera(int id,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    if (deny) throw CameraException('denied', 'camera denied');
    events.add(CameraInitializedEvent(
        id, 640, 480, ExposureMode.auto, false, FocusMode.auto, false));
  }

  @override
  Future<void> dispose(int id) async {
    disposed.add(id);
  }

  @override
  Future<XFile> takePicture(int id) async =>
      XFile.fromData(Uint8List.fromList([1, 2, 3]));
  @override
  Widget buildPreview(int id) => const SizedBox();
}

void main() {
  test('Windows camera requests no audio and releases the device', () async {
    final platform = FakeCamera();
    final camera = SsrvpnWindowsQrCamera(platform: platform);
    await camera.initialize();
    expect(camera.isInitialized, isTrue);
    expect(platform.settings!.enableAudio, isFalse);
    expect(platform.settings!.resolutionPreset, ResolutionPreset.medium);
    await camera.dispose();
    expect(camera.isInitialized, isFalse);
    expect(platform.disposed, [7]);
    await platform.events.close();
  });
  test('closing while device creation is pending releases its eventual device',
      () async {
    final platform = FakeCamera()..pendingCreate = Completer<int>();
    final camera = SsrvpnWindowsQrCamera(platform: platform);
    final opening = camera.initialize();
    await Future<void>.delayed(Duration.zero);
    await camera.dispose();
    platform.pendingCreate!.complete(7);
    await opening;
    expect(camera.isInitialized, isFalse);
    expect(platform.disposed, [7]);
    await platform.events.close();
  });
  test('permission denial leaves cleanup available', () async {
    final platform = FakeCamera()..deny = true;
    final camera = SsrvpnWindowsQrCamera(platform: platform);
    await expectLater(camera.initialize(), throwsA(isA<CameraException>()));
    await camera.dispose();
    expect(platform.disposed, [7]);
    await platform.events.close();
  });
}

import 'dart:async';
import 'dart:io';
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
  Completer<List<CameraDescription>>? pendingCameras;
  Completer<XFile>? pendingPicture;
  bool deny = false;
  @override
  Future<List<CameraDescription>> availableCameras() async =>
      pendingCameras?.future ??
      [
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
      pendingPicture?.future ?? XFile.fromData(Uint8List.fromList([1, 2, 3]));
  @override
  Widget buildPreview(int id) => const SizedBox();
}

class _CancelFailureCamera extends FakeCamera {
  final failingEvents = StreamController<CameraInitializedEvent>(
      onCancel: () async => throw StateError('native event channel closed'));
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int id) =>
      failingEvents.stream;
  @override
  Future<void> initializeCamera(int id,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    failingEvents.add(CameraInitializedEvent(
        id, 640, 480, ExposureMode.auto, false, FocusMode.auto, false));
  }
}

void main() {
  test('event channel cancellation failure still releases the native device',
      () async {
    final platform = _CancelFailureCamera();
    final camera = SsrvpnWindowsQrCamera(platform: platform);
    try {
      await camera.initialize();
    } catch (_) {
      // Cleanup must work even when initialization itself reported an error.
    }
    await camera.dispose();
    expect(platform.disposed, [7]);
    expect(camera.isInitialized, isFalse);
    await platform.events.close();
    await platform.failingEvents.close();
  });
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
    final failure = expectLater(opening, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await camera.dispose();
    platform.pendingCreate!.complete(7);
    await failure;
    await Future<void>.delayed(Duration.zero);
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
  testWidgets('closing cancels the timeout during stalled camera enumeration',
      (tester) async {
    final platform = FakeCamera()
      ..pendingCameras = Completer<List<CameraDescription>>();
    final camera = SsrvpnWindowsQrCamera(platform: platform);
    final failure = expectLater(camera.initialize(), throwsStateError);
    await tester.pump();
    await camera.dispose();
    await failure;
    await tester.pump();
    expect(camera.isInitialized, isFalse);
    expect(platform.disposed, isEmpty);
    await platform.events.close();
  });
  testWidgets('timed-out device creation releases a late native device',
      (tester) async {
    final platform = FakeCamera()..pendingCreate = Completer<int>();
    final camera = SsrvpnWindowsQrCamera(platform: platform);
    final opening = camera.initialize();
    final failure = expectLater(opening, throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await failure;
    platform.pendingCreate!.complete(7);
    await tester.pump();
    expect(camera.isInitialized, isFalse);
    expect(platform.disposed, [7]);
    await camera.dispose();
    await platform.events.close();
  });
  test('closing cancels a capture and deletes a late temporary photo',
      () async {
    final directory = await Directory.systemTemp.createTemp('ssrvpn-camera-');
    addTearDown(() => directory.delete(recursive: true));
    final photo = await File('${directory.path}/frame.jpg').writeAsBytes([1]);
    final platform = FakeCamera()..pendingPicture = Completer<XFile>();
    final camera = SsrvpnWindowsQrCamera(platform: platform);
    await camera.initialize();
    final failure = expectLater(camera.takePicture(), throwsStateError);
    await camera.dispose();
    await failure;
    platform.pendingPicture!.complete(XFile(photo.path));
    // Wait for the asynchronous deletion without relying on filesystem timing.
    for (var attempt = 0; attempt < 100 && await photo.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await photo.exists(), isFalse);
    expect(platform.disposed, [7]);
    await platform.events.close();
  });
}

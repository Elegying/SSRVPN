import 'dart:async';
import 'dart:io';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_qr_import_button.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_qr_scanner.dart';
import 'qr_test_image.dart';

class _DeniedWindowsCamera extends CameraPlatform {
  @override
  Future<List<CameraDescription>> availableCameras() async =>
      throw CameraException('denied', 'camera denied');
}

class _Scanner extends MobileScannerPlatform {
  final codes = StreamController<BarcodeCapture?>.broadcast();
  bool denied = false;
  Completer<void>? pendingStop;
  Completer<void>? pendingStart;
  int starts = 0, stops = 0;
  @override
  Stream<BarcodeCapture?> get barcodesStream => codes.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    await pendingStart?.future;
    if (denied) {
      throw const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied);
    }
    return const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.unavailable,
        size: Size(640, 480));
  }

  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<void> stop() async {
    stops++;
    await pendingStop?.future;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('gallery errors remain visible after the camera restarts',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final original = MobileScannerPlatform.instance;
    final scanner = _Scanner();
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = original;
      await scanner.codes.close();
    });
    await tester.pumpWidget(MaterialApp(
        home: SsrvpnQrScanner(
      pickImage: () async => XFile.fromData(qrPicture('ordinary text')),
    )));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择二维码图片'));
    await tester.tap(find.text('选择二维码图片'));
    for (var attempt = 0; attempt < 500; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.text('正在识别').evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(scanner.starts, 2);
    expect(find.text('未识别到有效节点或订阅链接，请换一个二维码'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, skip: Platform.isWindows);
  for (final close in [false, true]) {
    testWidgets('gallery result received while inactive: close=$close',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final original = MobileScannerPlatform.instance;
      final scanner = _Scanner()..denied = true;
      MobileScannerPlatform.instance = scanner;
      final originalCamera = CameraPlatform.instance;
      CameraPlatform.instance = _DeniedWindowsCamera();
      addTearDown(() async {
        MobileScannerPlatform.instance = original;
        CameraPlatform.instance = originalCamera;
        await scanner.codes.close();
      });
      const code = 'trojan://test-password@node.example.com:443#Gallery';
      final input = TextEditingController(text: 'existing draft');
      addTearDown(input.dispose);
      final picked = Completer<XFile?>();
      var imports = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SsrvpnQrImportButton(
                  enabled: true,
                  controller: input,
                  onAdd: () => imports++,
                  pickImage: () => picked.future))));
      await tester.tap(find.byKey(const Key('ssrvpn-qr-import')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('选择二维码图片'));
      await tester.tap(find.text('选择二维码图片'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.runAsync(() async {
        picked.complete(XFile.fromData(qrPicture(code)));
      });
      // Image decoding runs in a real isolate, outside the widget test clock.
      for (var attempt = 0; attempt < 500; attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        if (find.text('正在识别').evaluate().isEmpty) break;
      }
      expect(find.text('正在识别'), findsNothing);
      expect(find.text('导入二维码'), findsNothing);
      expect(imports, 0);
      expect(input.text, 'existing draft');
      if (close) {
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      if (close) {
        expect(find.text('导入二维码'), findsNothing);
        expect(input.text, 'existing draft');
      } else {
        expect(find.text('导入二维码'), findsOneWidget);
        await tester.tap(find.text('导入'));
        await tester.pumpAndSettle();
        expect(imports, 1);
        expect(input.text, code);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('reopening waits for the old route to release its camera',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final original = MobileScannerPlatform.instance;
    final scanner = _Scanner();
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = original;
      await scanner.codes.close();
    });
    await tester.pumpWidget(
        const MaterialApp(home: SsrvpnQrScanner(key: ValueKey('first'))));
    await tester.pumpAndSettle();
    scanner.pendingStop = Completer<void>();
    await tester.pumpWidget(
        const MaterialApp(home: SsrvpnQrScanner(key: ValueKey('second'))));
    await tester.pump();
    expect(scanner.starts, 1);
    expect(scanner.stops, 1);
    scanner.pendingStop!.complete();
    scanner.pendingStop = null;
    await tester.pumpAndSettle();
    expect(scanner.starts, 2);
    expect(scanner.stops, 1,
        reason: 'old route cleanup must not stop the new session');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(scanner.stops, 2);
  }, skip: Platform.isWindows);
  testWidgets('closing during camera startup stops the late native session',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final original = MobileScannerPlatform.instance;
    final scanner = _Scanner()..pendingStart = Completer<void>();
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = original;
      await scanner.codes.close();
    });
    await tester.pumpWidget(const MaterialApp(home: SsrvpnQrScanner()));
    await tester.pump();
    expect(scanner.starts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    scanner.pendingStart!.complete();
    await tester.pumpAndSettle();
    expect(scanner.stops, 1);
    expect(tester.takeException(), isNull);
  }, skip: Platform.isWindows);
  testWidgets('resume waits for the previous native camera stop to finish',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final original = MobileScannerPlatform.instance;
    final scanner = _Scanner();
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = original;
      await scanner.codes.close();
    });
    await tester.pumpWidget(const MaterialApp(home: SsrvpnQrScanner()));
    await tester.pumpAndSettle();
    expect(scanner.starts, 1);
    scanner.pendingStop = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(scanner.starts, 1,
        reason: 'the old native session still owns the camera');
    scanner.pendingStop!.complete();
    scanner.pendingStop = null;
    await tester.pumpAndSettle();
    expect(scanner.starts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, skip: Platform.isWindows);
  // Windows uses camera_windows; its adapter has separate lifecycle tests.
  testWidgets(
      'scanned node requires confirmation and cancel preserves an existing draft',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final original = MobileScannerPlatform.instance, scanner = _Scanner();
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = original;
      await scanner.codes.close();
    });
    final input = TextEditingController(text: 'existing draft');
    addTearDown(input.dispose);
    var imports = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnQrImportButton(
                enabled: true, controller: input, onAdd: () => imports++))));
    await tester.tap(find.byKey(const Key('ssrvpn-qr-import')));
    await tester.pumpAndSettle();
    scanner.codes.add(const BarcodeCapture(
        barcodes: [Barcode(rawValue: 'https://example.com/feed')]));
    await tester.pumpAndSettle();
    expect(find.text('导入二维码'), findsOneWidget);
    expect(imports, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(input.text, 'existing draft');
    await tester.tap(find.byKey(const Key('ssrvpn-qr-import')));
    await tester.pumpAndSettle();
    scanner.codes.add(const BarcodeCapture(barcodes: [
      Barcode(rawValue: 'javascript:alert(1)'),
      Barcode(rawValue: 'trojan://test-password@node.example.com:443#Test')
    ]));
    await tester.pumpAndSettle();
    expect(find.text('导入二维码'), findsOneWidget);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(input.text, 'trojan://test-password@node.example.com:443#Test');
    expect(scanner.stops, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: Platform.isWindows);
  testWidgets(
      'camera denial leaves gallery selection and cancellation available',
      (tester) async {
    final originalCamera = CameraPlatform.instance;
    CameraPlatform.instance = _DeniedWindowsCamera();
    addTearDown(() => CameraPlatform.instance = originalCamera);
    tester.view.physicalSize = const Size(320, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final original = MobileScannerPlatform.instance,
        scanner = _Scanner()..denied = true;
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = original;
      await scanner.codes.close();
    });
    final input = TextEditingController();
    addTearDown(input.dispose);
    var picks = 0;
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(
            body: SsrvpnQrImportButton(
                enabled: true,
                controller: input,
                onAdd: () => fail('must not import'),
                pickImage: () async {
                  picks++;
                  return null;
                }))));
    await tester.tap(find.byKey(const Key('ssrvpn-qr-import')));
    await tester.pumpAndSettle();
    expect(find.text('选择二维码图片'), findsOneWidget);
    await tester.ensureVisible(find.text('选择二维码图片'));
    await tester.tap(find.text('选择二维码图片'));
    await tester.pumpAndSettle();
    expect(picks, 1);
    expect(input.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

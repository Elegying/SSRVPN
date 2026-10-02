import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_qr_import_button.dart';

class _Scanner extends MobileScannerPlatform {
  final codes = StreamController<BarcodeCapture?>.broadcast();
  bool denied = false;
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
  }

  @override
  Future<void> dispose() async {}
}

void main() {
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
  });
  testWidgets(
      'camera denial leaves gallery selection and cancellation available',
      (tester) async {
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

import 'dart:async';
import 'dart:io';
import 'ssrvpn_windows_qr_camera.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/qr_image_decoder.dart';
import '../utils/node_import_policy.dart';

class SsrvpnQrScanner extends StatefulWidget {
  const SsrvpnQrScanner({super.key, this.pickImage});
  final Future<XFile?> Function()? pickImage;
  @override
  State<SsrvpnQrScanner> createState() => _SsrvpnQrScannerState();
}

class _SsrvpnQrScannerState extends State<SsrvpnQrScanner>
    with WidgetsBindingObserver {
  final _scanner = Platform.isWindows
      ? null
      : MobileScannerController(
          autoStart: false,
          formats: [BarcodeFormat.qrCode],
          detectionSpeed: DetectionSpeed.noDuplicates,
        );
  SsrvpnWindowsQrCamera? _camera, _openingCamera;
  Timer? _timer;
  int _epoch = 0;
  bool _starting = false, _picking = false, _capturing = false, _done = false;
  String? _notice;
  int _cameraFailures = 0;
  bool get _active =>
      mounted &&
      !_done &&
      !_picking &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      ModalRoute.of(context)?.isCurrent != false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      _stop();
    }
  }

  Future<void> _start() async {
    if (!_active || _starting) return;
    _starting = true;
    final epoch = _epoch;
    SsrvpnWindowsQrCamera? initializing;
    try {
      if (Platform.isWindows) {
        if (_camera != null) return;
        initializing = SsrvpnWindowsQrCamera();
        _openingCamera = initializing;
        await initializing.initialize();
        if (!_active || epoch != _epoch) {
          await initializing.dispose();
          return;
        }
        _camera = initializing;
        setState(() => _notice = null);
        _timer = Timer.periodic(const Duration(seconds: 1), (_) => _capture());
      } else {
        await _scanner!.start();
        if (!_active || epoch != _epoch) {
          await _scanner.stop();
          return;
        }
        if (mounted) setState(() => _notice = null);
      }
    } catch (_) {
      if (initializing != null && !identical(_camera, initializing)) {
        try {
          await initializing.dispose();
        } catch (_) {}
      }
      if (mounted && epoch == _epoch) {
        setState(() => _notice = '相机不可用或权限未开启。可选择二维码图片，或开启相机权限后重试。');
      }
    } finally {
      _openingCamera = null;
      _starting = false;
      if (_active && epoch != _epoch) _start();
    }
  }

  Future<void> _stop() async {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    final camera = _camera;
    _camera = null;
    await _openingCamera?.dispose();
    _openingCamera = null;
    if (camera != null) {
      try {
        await camera.dispose();
      } catch (_) {}
    }
    if (!Platform.isWindows) {
      try {
        await _scanner!.stop();
      } catch (_) {}
    }
  }

  void _accept(String? value) {
    if (!_active) return;
    final candidate = NodeImportPolicy.candidate(
      value,
      allowSubscription: true,
    );
    if (candidate == null) {
      setState(() => _notice = '未识别到有效节点或订阅链接，请换一个二维码');
      return;
    }
    _done = true;
    _stop();
    Navigator.of(context).pop(candidate);
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (!_active || _capturing || camera == null || !camera.isInitialized) {
      return;
    }
    _capturing = true;
    final epoch = _epoch;
    XFile? photo;
    try {
      photo = await camera.takePicture();
      final code = await QrImageDecoder.read(photo);
      _cameraFailures = 0;
      if (_active && epoch == _epoch && code != null) _accept(code);
    } catch (_) {
      if (_active && epoch == _epoch && ++_cameraFailures >= 3) {
        setState(() => _notice = '相机读取失败，请重试相机或选择二维码图片');
        await _stop();
      }
      /* A frame can fail while the camera is being closed. */
    } finally {
      if (photo != null) {
        try {
          await File(photo.path).delete();
        } catch (_) {}
      }
      _capturing = false;
    }
  }

  Future<void> _pick() async {
    if (_picking || _done) return;
    setState(() => _picking = true);
    await _stop();
    try {
      final file = widget.pickImage != null
          ? await widget.pickImage!()
          : await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: '二维码图片',
                  extensions: ['png', 'jpg', 'jpeg', 'webp'],
                  uniformTypeIdentifiers: ['public.image'],
                ),
              ],
            );
      if (!mounted || file == null) return;
      final value = await QrImageDecoder.read(file);
      if (!mounted) return;
      _picking = false;
      if (value != null) {
        _accept(value);
      } else {
        setState(() => _notice = '图片中未找到二维码，请选择清晰的二维码图片');
      }
    } catch (_) {
      if (mounted) setState(() => _notice = '图片读取失败、过大或格式不支持，请裁剪二维码后重试');
    } finally {
      _picking = false;
      if (mounted) {
        setState(() {});
        _start();
      }
    }
  }

  @override
  void dispose() {
    _done = true;
    _stop().whenComplete(() async {
      if (_scanner != null) {
        try {
          await _scanner.dispose();
        } catch (_) {}
      }
    });
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('扫描二维码')),
        body: SafeArea(
          child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                      child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('将节点或订阅二维码放入画面。识别后需要确认导入。'),
                      ),
                      SizedBox(
                        height:
                            (constraints.maxHeight * .55).clamp(160.0, 420.0),
                        child: Platform.isWindows
                            ? _camera == null
                                ? const Center(
                                    child: Icon(Icons.videocam_off_outlined,
                                        size: 64),
                                  )
                                : _camera!.preview()
                            : MobileScanner(
                                controller: _scanner,
                                onDetect: (capture) {
                                  for (final barcode in capture.barcodes) {
                                    if (NodeImportPolicy.candidate(
                                            barcode.rawValue,
                                            allowSubscription: true) !=
                                        null) {
                                      _accept(barcode.rawValue);
                                      break;
                                    }
                                  }
                                },
                                errorBuilder: (context, error) => const Center(
                                    child: Text('无法使用相机，可选择二维码图片')),
                              ),
                      ),
                      if (_notice != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Semantics(
                              liveRegion: true, child: Text(_notice!)),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 12,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _picking ? null : _pick,
                              icon: const Icon(Icons.photo_library_outlined),
                              label: Text(_picking ? '正在识别' : '选择二维码图片'),
                            ),
                            TextButton(
                              onPressed: _picking
                                  ? null
                                  : () async {
                                      await _stop();
                                      _start();
                                    },
                              child: const Text('重试相机'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ))),
        ),
      );
}

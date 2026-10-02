import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../utils/app_modal_coordinator.dart';
import 'ssrvpn_qr_scanner.dart';
import 'ssrvpn_liquid_dialog.dart';
import 'ssrvpn_glass_dialog_route.dart';

class SsrvpnQrImportButton extends StatefulWidget {
  const SsrvpnQrImportButton({
    super.key,
    required this.enabled,
    required this.controller,
    required this.onAdd,
    this.pickImage,
  });
  final bool enabled;
  final TextEditingController controller;
  final VoidCallback onAdd;
  final Future<XFile?> Function()? pickImage;
  @override
  State<SsrvpnQrImportButton> createState() => _SsrvpnQrImportButtonState();
}

class _SsrvpnQrImportButtonState extends State<SsrvpnQrImportButton> {
  bool _busy = false;
  Future<void> _scan() async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    try {
      await AppModalCoordinator.run<void>(() async {
        if (!mounted || !widget.enabled) return;
        final value = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => SsrvpnQrScanner(pickImage: widget.pickImage),
          ),
        );
        if (!mounted || value == null || !widget.enabled) return;
        final accepted = await showSsrvpnGlassDialog<bool>(
          context: context,
          builder: (ctx) => SsrvpnLiquidAlertDialog(
            title: const Text('导入二维码'),
            content: Text(
              widget.controller.text.trim().isEmpty
                  ? '是否导入识别到的节点或订阅？'
                  : '是否用二维码内容替换输入框并导入？',
            ),
            actions: [
              TextButton(
                onPressed: () => dismissSsrvpnDialog(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => dismissSsrvpnDialog(ctx, true),
                child: const Text('导入'),
              ),
            ],
          ),
        );
        if (mounted && widget.enabled && accepted == true) {
          widget.controller.text = value;
          widget.onAdd();
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
        key: const Key('ssrvpn-qr-import'),
        tooltip: '扫描或选择二维码图片',
        onPressed: widget.enabled && !_busy ? _scan : null,
        icon: const Icon(Icons.qr_code_scanner_rounded),
      );
}

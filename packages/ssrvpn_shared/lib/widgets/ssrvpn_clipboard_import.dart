import '../services/subscription_service_base.dart';
import '../controllers/subscription_screen_controller.dart';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/app_modal_coordinator.dart';
import '../utils/node_import_policy.dart';
import 'ssrvpn_glass_dialog_route.dart';
import 'ssrvpn_liquid_dialog.dart';

/// Reads only while the app is resumed. Bounded in-memory hashes suppress repeats.
class SsrvpnClipboardImport extends StatefulWidget {
  const SsrvpnClipboardImport({
    super.key,
    required this.child,
    required this.onImport,
    required this.alreadyImported,
  });
  final Widget child;
  final Future<String> Function(String) onImport;
  final bool Function(String) alreadyImported;
  @override
  State<SsrvpnClipboardImport> createState() => _SsrvpnClipboardImportState();
}

class _SsrvpnClipboardImportState extends State<SsrvpnClipboardImport>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _busy = false;
  bool _active = false;
  int _epoch = 0;
  Route<dynamic>? _promptRoute;
  final _seen = <String>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resume();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    _timer?.cancel();
    _active = state == AppLifecycleState.resumed;
    if (!_active && _promptRoute?.isCurrent == true) {
      _promptRoute!.navigator?.pop(false);
    }
    if (_active) _resume();
  }

  void _resume() {
    _active =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!_active) return;
    _timer?.cancel();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  Future<void> _check() async {
    if (_busy ||
        !_active ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _busy = true;
    final epoch = _epoch;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted ||
          !_active ||
          epoch != _epoch ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final candidate = NodeImportPolicy.candidate(data?.text);
      if (candidate == null || widget.alreadyImported(candidate)) return;
      final fingerprint = sha256.convert(utf8.encode(candidate)).toString();
      if (_seen.contains(fingerprint)) return;
      // Do not retain node credentials in deduplication history.
      if (_seen.length >= 128) _seen.remove(_seen.first);
      await AppModalCoordinator.run<void>(() async {
        if (!mounted ||
            !_active ||
            epoch != _epoch ||
            widget.alreadyImported(candidate) ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        _seen.add(fingerprint);
        final accepted = await showSsrvpnGlassDialog<bool>(
          context: context,
          builder: (ctx) {
            _promptRoute = ModalRoute.of(ctx);
            return SsrvpnLiquidAlertDialog(
              title: const Text('发现剪贴板节点'),
              content: const Text('是否导入复制的节点？'),
              actions: [
                TextButton(
                  onPressed: () => dismissSsrvpnDialog(ctx, false),
                  child: const Text('暂不导入'),
                ),
                FilledButton(
                  onPressed: () => dismissSsrvpnDialog(ctx, true),
                  child: const Text('导入'),
                ),
              ],
            );
          },
        );
        _promptRoute = null;
        if (accepted != true || !mounted || !_active || epoch != _epoch) return;
        final message = await widget.onImport(candidate);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      });
    } catch (_) {
      /* OS denial and unavailable clipboard are non-fatal. */
    } finally {
      _promptRoute = null;
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class SsrvpnServiceClipboardImport extends StatelessWidget {
  const SsrvpnServiceClipboardImport({
    super.key,
    required this.service,
    required this.child,
  });
  final SubscriptionServiceBase service;
  final Widget child;
  @override
  Widget build(BuildContext context) => SsrvpnClipboardImport(
        alreadyImported: (value) =>
            service.subscriptions.any((sub) => sub.url == value),
        onImport: (value) async {
          final result = await SubscriptionScreenController.fromService(
            service,
          ).addSubscription(value);
          return result.isSuccess
              ? '节点已导入'
              : result.status == SubscriptionAddStatus.duplicate
                  ? '节点已存在'
                  : '导入失败，请检查节点代码后重试';
        },
        child: child,
      );
}

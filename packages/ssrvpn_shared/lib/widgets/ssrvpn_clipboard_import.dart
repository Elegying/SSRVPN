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
    this.shouldShowNotice,
    this.onDiagnostic,
    required this.onImport,
    required this.alreadyImported,
  });
  final Widget child;
  final bool Function()? shouldShowNotice;
  final ValueChanged<String>? onDiagnostic;
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
  String? _failedFingerprint;
  GlobalKey? _noticeKey;
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
      final fingerprint = candidate == null
          ? null
          : sha256.convert(utf8.encode(candidate)).toString();
      // A failed attempt stays quiet until the clipboard changes. Retain only
      // its digest so copying the node again can request a new confirmation.
      if (_failedFingerprint != null && fingerprint != _failedFingerprint) {
        _seen.remove(_failedFingerprint);
        _failedFingerprint = null;
      }
      if (candidate == null || widget.alreadyImported(candidate)) return;
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
        _seen.add(fingerprint!);
        var declined = false;
        final accepted = await showSsrvpnGlassDialog<bool>(
          context: context,
          builder: (ctx) {
            _promptRoute = ModalRoute.of(ctx);
            return SsrvpnLiquidAlertDialog(
              title: const Text('发现剪贴板节点'),
              content: const Text('是否导入复制的节点？'),
              actions: [
                TextButton(
                  onPressed: () {
                    declined = true;
                    dismissSsrvpnDialog(ctx, false);
                  },
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
        if (epoch != _epoch) {
          // Lifecycle dismissal is not an explicit decision by the user.
          if (!declined) _seen.remove(fingerprint);
          return;
        }
        if (accepted != true || !mounted || !_active) return;
        String message;
        try {
          message = await widget.onImport(candidate);
        } catch (_) {
          message = '导入失败，请检查节点代码后点击重试';
        } finally {
          if (!widget.alreadyImported(candidate)) {
            _failedFingerprint = fingerprint;
          }
        }
        if (mounted) {
          widget.onDiagnostic?.call(message);
          if (widget.shouldShowNotice?.call() == false) return;
          final messenger = ScaffoldMessenger.of(context);
          // Remove only this flow's visible notice, not another feature's feedback.
          if (_noticeKey?.currentContext != null) {
            messenger.removeCurrentSnackBar();
          }
          final noticeKey = GlobalKey();
          _noticeKey = noticeKey;
          messenger.showSnackBar(SnackBar(
            content: Text(message, key: noticeKey),
            action: _failedFingerprint == fingerprint
                ? SnackBarAction(
                    label: '重试',
                    onPressed: () {
                      _seen.remove(fingerprint);
                      if (_failedFingerprint == fingerprint) {
                        _failedFingerprint = null;
                      }
                      _check();
                    })
                : null,
          ));
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
    this.shouldShowNotice,
    this.onDiagnostic,
  });
  final SubscriptionServiceBase service;
  final Widget child;
  final bool Function()? shouldShowNotice;
  final ValueChanged<String>? onDiagnostic;
  @override
  Widget build(BuildContext context) => SsrvpnClipboardImport(
        shouldShowNotice: shouldShowNotice,
        onDiagnostic: onDiagnostic,
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
                  : '导入失败，请检查节点代码后点击重试';
        },
        child: child,
      );
}

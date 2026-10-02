import 'package:flutter/material.dart';
import '../services/clash_service_base.dart';
import '../services/site_access_diagnostic.dart';
import 'ssrvpn_glass_dialog_route.dart';
import 'ssrvpn_liquid_dialog.dart';

Future<void> showSsrvpnSiteDiagnostic(
  BuildContext context,
  ClashServiceBase core,
) =>
    showSsrvpnGlassDialog<void>(
      context: context,
      builder: (_) => _SiteDiagnosticDialog(core: core),
    );

class _SiteDiagnosticDialog extends StatefulWidget {
  const _SiteDiagnosticDialog({required this.core});
  final ClashServiceBase core;
  @override
  State<_SiteDiagnosticDialog> createState() => _SiteDiagnosticDialogState();
}

class _SiteDiagnosticDialogState extends State<_SiteDiagnosticDialog>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  SiteAccessDiagnostic? _running;
  String? _result;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    widget.core.addStatusListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (_running == null) return;
    // Any core transition invalidates this advisory result; never repair or switch automatically.
    _epoch++;
    _running?.cancel();
    if (mounted) setState(() => _result = '连接状态已变化，请重新诊断');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _changed();
  }

  Future<void> _run() async {
    if (_running != null) return;
    Uri target;
    try {
      target = SiteAccessDiagnostic.parseTarget(_input.text.trim());
    } on FormatException catch (e) {
      setState(() => _result = e.message);
      return;
    }
    final core = widget.core;
    final intent = core.captureAutomaticRestartIntent();
    if (!core.isRunning ||
        !core.connectionDesired ||
        intent == null ||
        core.isProxySelectionInProgress) {
      setState(() => _result = '请先连接节点，等待节点切换完成后再诊断');
      return;
    }
    final epoch = ++_epoch;
    final check = SiteAccessDiagnostic();
    setState(() {
      _running = check;
      _result = null;
    });
    try {
      final selected = await core.currentSelectedProxyName();
      if (!mounted ||
          epoch != _epoch ||
          !core.isConnectionIntentCurrent(intent, connected: true)) {
        return;
      }
      final message = await check.run(target, proxyPort: core.runtimeProxyPort);
      final current = await core.currentSelectedProxyName();
      if (!mounted ||
          epoch != _epoch ||
          !core.isConnectionIntentCurrent(intent, connected: true)) {
        return;
      }
      setState(
        () => _result = selected != current || core.isProxySelectionInProgress
            ? '节点已变化，请重新诊断'
            : message,
      );
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _result = '当前连接不可用，请重新连接后诊断');
      }
    } finally {
      check.cancel();
      if (mounted) setState(() => _running = null);
    }
  }

  @override
  void dispose() {
    _epoch++;
    _running?.cancel();
    _input.dispose();
    widget.core.removeStatusListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SsrvpnLiquidAlertDialog(
        title: const Text('网站访问诊断'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('按当前连接和路由规则检测网站响应。不会自动切换节点，结果不保存。'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('ssrvpn-site-diagnostic-input'),
                  controller: _input,
                  maxLength: 2048,
                  enabled: _running == null,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com',
                  ),
                  onSubmitted: (_) => _run(),
                ),
                if (_running != null) const LinearProgressIndicator(),
                if (_result != null)
                  Semantics(liveRegion: true, child: Text(_result!)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => dismissSsrvpnDialog<void>(context),
            child: const Text('关闭'),
          ),
          if (_running != null)
            TextButton(
              onPressed: () {
                _epoch++;
                _running?.cancel();
                setState(() => _result = '诊断已取消');
              },
              child: const Text('取消诊断'),
            )
          else
            FilledButton(onPressed: _run, child: const Text('开始诊断')),
        ],
      );
}

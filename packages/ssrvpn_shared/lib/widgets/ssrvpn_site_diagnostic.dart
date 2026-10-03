import 'ssrvpn_theme_icon.dart';
import 'ssrvpn_theme.dart';
import 'package:flutter/material.dart';
import '../models/site_diagnostic_report.dart';
import '../constants/app_constants.dart';
import 'ssrvpn_site_diagnostic_result.dart';
import '../services/clash_service_base.dart';
import '../services/site_access_diagnostic.dart';
import 'ssrvpn_glass_dialog_route.dart';
import 'ssrvpn_liquid_dialog.dart';

Future<void> showSsrvpnSiteDiagnostic(
  BuildContext context,
  ClashServiceBase core, {
  Future<void> Function(String host, bool direct)? onAddRoutingSite,
  SiteAccessDiagnostic Function() createDiagnostic = SiteAccessDiagnostic.new,
}) =>
    showSsrvpnGlassDialog<void>(
      context: context,
      builder: (_) => _SiteDiagnosticDialog(
          core: core,
          onAddRoutingSite: onAddRoutingSite,
          createDiagnostic: createDiagnostic),
    );

class _SiteDiagnosticDialog extends StatefulWidget {
  const _SiteDiagnosticDialog(
      {required this.core,
      this.onAddRoutingSite,
      required this.createDiagnostic});
  final SiteAccessDiagnostic Function() createDiagnostic;
  final Future<void> Function(String host, bool direct)? onAddRoutingSite;
  final ClashServiceBase core;
  @override
  State<_SiteDiagnosticDialog> createState() => _SiteDiagnosticDialogState();
}

class _SiteDiagnosticDialogState extends State<_SiteDiagnosticDialog>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  SiteAccessDiagnostic? _running;
  String? _result;
  SiteDiagnosticReport? _report;
  String? _stage;
  bool? _pendingDirect;
  bool _savingRule = false;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    widget.core.addStatusListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (_running == null && _report == null) return;
    // Any core transition invalidates this advisory result; never repair or switch automatically.
    _epoch++;
    _running?.cancel();
    if (mounted) {
      setState(() {
        _report = null;
        _pendingDirect = null;
        _result = '连接状态已变化，请重新诊断';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _changed();
  }

  Future<void> _run() async {
    if (_running != null || _savingRule) return;
    setState(() {
      _report = null;
      _pendingDirect = null;
    });
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
    final check = widget.createDiagnostic();
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
      var report = await check.inspect(target,
          proxyPort: core.runtimeProxyPort,
          apiPort: core.runtimeApiPort,
          apiHeaders: core.apiHeaders(), onStage: (stage) {
        if (mounted && epoch == _epoch) setState(() => _stage = stage);
      });
      if (!report.succeeded &&
          mounted &&
          epoch == _epoch &&
          core.isConnectionIntentCurrent(intent, connected: true) &&
          target.host !=
              Uri.parse(AppConstants.fallbackConnectivityTestUrl).host) {
        final reference = await check.inspect(
            Uri.parse(AppConstants.fallbackConnectivityTestUrl),
            proxyPort: core.runtimeProxyPort,
            apiPort: core.runtimeApiPort,
            apiHeaders: core.apiHeaders(), onStage: (stage) {
          if (mounted && epoch == _epoch) {
            setState(() => _stage = '补充检查参考站点：$stage');
          }
        });
        report = report.withReference(reference);
      }
      final current = await core.currentSelectedProxyName();
      if (!mounted ||
          epoch != _epoch ||
          !core.isConnectionIntentCurrent(intent, connected: true)) {
        return;
      }
      setState(() {
        if (selected != current || core.isProxySelectionInProgress) {
          _result = '节点已变化，请重新诊断';
        } else {
          _report = report;
        }
      });
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _result = '当前连接不可用，请重新连接后诊断');
      }
    } finally {
      check.cancel();
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _saveRule() async {
    final report = _report;
    final direct = _pendingDirect;
    if (_savingRule ||
        report == null ||
        direct == null ||
        widget.onAddRoutingSite == null) {
      return;
    }
    setState(() => _savingRule = true);
    try {
      await widget.onAddRoutingSite!(report.host, direct);
      if (mounted) {
        setState(() {
          _pendingDirect = null;
          _report = null;
          _result = '规则已保存；请重新连接后再诊断，当前连接尚未切换到新规则';
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _result = error.message);
    } catch (_) {
      if (mounted) setState(() => _result = '保存失败，请重试；未确认规则生效');
    } finally {
      if (mounted) setState(() => _savingRule = false);
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
        title: Row(children: [
          if (!SsrvpnTheme.of(context).isDefault) ...[
            const SsrvpnThemeIcon('diagnostic', fallback: Icons.travel_explore),
            const SizedBox(width: 10),
          ],
          const Expanded(child: Text('网站访问诊断')),
        ]),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('ssrvpn-site-diagnostic-input'),
                  controller: _input,
                  maxLength: 2048,
                  enabled: _running == null && !_savingRule,
                  autocorrect: false,
                  enableSuggestions: true,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com',
                  ),
                  onChanged: (_) => setState(() {
                    _report = null;
                    _result = null;
                    _pendingDirect = null;
                  }),
                  onSubmitted: (_) => _run(),
                ),
                if (_running != null) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_stage ?? '正在诊断…'),
                ],
                if (_report != null) ...[
                  SsrvpnSiteDiagnosticResult(report: _report!),
                  if (widget.onAddRoutingSite != null &&
                      !_report!.succeeded) ...[
                    const Text('调整此网站规则（可选）'),
                    Wrap(spacing: 8, children: [
                      TextButton(
                          onPressed: _savingRule
                              ? null
                              : () => setState(() => _pendingDirect = false),
                          child: const Text('添加强制代理')),
                      TextButton(
                          onPressed: _savingRule
                              ? null
                              : () => setState(() => _pendingDirect = true),
                          child: const Text('添加强制直连')),
                    ]),
                    if (_pendingDirect != null) ...[
                      Text(
                          '将 ${_report!.host} 及其子域名加入${_pendingDirect! ? '强制直连（使用本地网络出口）' : '强制代理'}。不会覆盖已有规则，保存后需重新连接；不保证解决网站自身问题。'),
                      Wrap(spacing: 8, children: [
                        TextButton(
                            onPressed: _savingRule
                                ? null
                                : () => setState(() => _pendingDirect = null),
                            child: const Text('暂不修改')),
                        FilledButton(
                            onPressed: _savingRule ? null : _saveRule,
                            child: Text(_savingRule ? '正在保存…' : '确认保存规则')),
                      ]),
                    ],
                  ],
                ],
                if (_result != null)
                  Semantics(liveRegion: true, child: Text(_result!)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _epoch++;
              _running?.cancel();
              dismissSsrvpnDialog<void>(context);
            },
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
            FilledButton(
                onPressed: _savingRule ? null : _run,
                child: const Text('开始诊断')),
        ],
      );
}

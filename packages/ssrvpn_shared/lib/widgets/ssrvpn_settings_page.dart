import '../services/subscription_service_base.dart';
import 'ssrvpn_subscription_schedule_dialog.dart';
import 'ssrvpn_theme_icon.dart';
import 'ssrvpn_theme.dart';
import 'ssrvpn_theme_picker.dart';
import 'ssrvpn_site_diagnostic.dart';
import '../utils/site_routing_suggestion.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/app_settings.dart';
import '../services/clash_service_base.dart';
import '../services/update_checker.dart';
import 'ssrvpn_diagnostics_dialog.dart';
import 'ssrvpn_liquid_glass.dart';

class SsrvpnSettingsPage extends StatefulWidget {
  const SsrvpnSettingsPage(
      {super.key,
      required this.settings,
      this.subscriptionService,
      required this.core,
      required this.onAppearanceChanged,
      required this.onPortChanged,
      required this.checkForUpdate,
      required this.onUpdateFound,
      this.onRoutingSitesChanged});
  final Future<void> Function(List<String> sites, bool direct)?
      onRoutingSitesChanged;
  final AppSettings settings;
  final SubscriptionServiceBase? subscriptionService;
  final ClashServiceBase core;
  final Future<void> Function({AppThemeVariant? themeVariant})
      onAppearanceChanged;
  final Future<void> Function(int) onPortChanged;
  final Future<AppUpdateInfo?> Function() checkForUpdate;
  final void Function(AppUpdateInfo) onUpdateFound;
  @override
  State<SsrvpnSettingsPage> createState() => _SsrvpnSettingsPageState();
}

class _SsrvpnSettingsPageState extends State<SsrvpnSettingsPage> {
  late final TextEditingController _port;
  final _siteDiagnosticFocus = FocusNode();
  final _runtimeLogFocus = FocusNode();
  bool _saving = false;
  bool _checking = false;
  bool _checkingRules = false;
  String? _noticeText;
  String _noticeLocation = 'appearance';
  Timer? _noticeTimer;
  String? get _notice => _noticeText;
  set _notice(String? value) {
    _noticeTimer?.cancel();
    _noticeText = value;
    if (value != null) {
      _noticeTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _noticeText = null);
      });
    }
  }

  String? _portError;
  @override
  void initState() {
    super.initState();
    _port = TextEditingController(text: '${widget.settings.proxyPort}');
    widget.core.addStatusListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.core.removeStatusListener(_refresh);
    _noticeTimer?.cancel();
    _port.dispose();
    _siteDiagnosticFocus.dispose();
    _runtimeLogFocus.dispose();
    super.dispose();
  }

  void _showNotice(String message, String location) => setState(() {
        _noticeLocation = location;
        _notice = message;
      });

  Future<void> _save(Future<void> Function() action, String? success,
      {String location = 'appearance'}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await action();
      if (mounted && success != null) _showNotice(success, location);
    } catch (_) {
      if (mounted) _showNotice('保存失败，原设置已保留，请重试', location);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _savePort() async {
    final value = int.tryParse(_port.text.trim());
    final error = value == null || value < 1024 || value > 65535
        ? '请输入 1024–65535 之间的端口'
        : value == widget.settings.socksPort || value == widget.settings.apiPort
            ? '不能与 SOCKS 或控制端口重复'
            : null;
    setState(() => _portError = error);
    if (error != null) return;
    FocusScope.of(context).unfocus();
    await _save(() => widget.onPortChanged(value!), '代理端口已保存，下次连接生效',
        location: 'port');
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _notice = null;
    });
    try {
      final update = await widget.checkForUpdate();
      if (!mounted) return;
      if (update != null) widget.onUpdateFound(update);
      _showNotice(
          update == null ? '当前已是最新版本' : '发现新版本 ${update.version}，可点击底部更新入口',
          'update');
    } catch (error) {
      if (mounted) {
        _showNotice(UpdateChecker.checkFailureMessage(error), 'update');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _checkRules() async {
    if (_checkingRules) return;
    setState(() {
      _checkingRules = true;
      _notice = null;
    });
    try {
      final message = await widget.core.checkRuleUpdates();
      if (mounted) _showNotice(message, 'rules');
    } catch (_) {
      if (mounted) _showNotice('规则检查失败，请稍后重试', 'rules');
    } finally {
      if (mounted) setState(() => _checkingRules = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = width > 680 ? (width - 640) / 2 : 20.0;
    return SafeArea(
        bottom: false,
        child: Column(children: [
          Expanded(
              child: ListView(
                  key: const PageStorageKey('settings-page'),
                  padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      12,
                      horizontalPadding,
                      MediaQuery.paddingOf(context).bottom + 24),
                  children: [
                const Text('设置',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                _section('外观', [
                  SsrvpnThemePicker(
                    selected: widget.settings.themeVariant,
                    onChanged: _saving
                        ? null
                        : (theme) => _save(
                              () => widget.onAppearanceChanged(
                                  themeVariant: theme),
                              null,
                            ),
                  ),
                  if (_notice != null && _noticeLocation == 'appearance')
                    _noticeView(),
                ]),
                const SizedBox(height: 14),
                _section(
                    '代理端口',
                    [
                      Text(
                          widget.core.isRunning
                              ? '当前实际端口：${widget.core.runtimeProxyPort}'
                              : '已保存端口：${widget.settings.proxyPort}',
                          style: TextStyle(
                              fontSize: 12,
                              color: SsrvpnTheme.of(context).textSecondary)),
                      const SizedBox(height: 10),
                      Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                              onPressed: _saving ? null : _savePort,
                              child: const Text('保存端口'))),
                      if (_notice != null && _noticeLocation == 'port')
                        _noticeView(),
                    ],
                    header: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(
                              width: 80,
                              child: Text('代理端口',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold))),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                                controller: _port,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(5)
                                ],
                                decoration: InputDecoration(
                                    hintText: '下次连接生效',
                                    hintMaxLines: 3,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 12),
                                    border: const OutlineInputBorder(),
                                    errorMaxLines: 8,
                                    errorText: _portError),
                                onSubmitted:
                                    _saving ? null : (_) => _savePort()),
                          ),
                        ])),
                const SizedBox(height: 12),
                _section('应用', [
                  if (widget.subscriptionService != null)
                    SubscriptionScheduleTile(
                        service: widget.subscriptionService!),
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const SsrvpnThemeIcon('logs',
                          fallback: Icons.rule_folder_outlined),
                      title: const Text('检查规则更新'),
                      trailing: _checkingRules
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.chevron_right),
                      onTap: _checkingRules ? null : _checkRules),
                  if (_notice != null && _noticeLocation == 'rules')
                    _noticeView(),
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const SsrvpnThemeIcon('download',
                          fallback: Icons.system_update_outlined),
                      title: const Text('检查软件更新'),
                      trailing: _checking
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.chevron_right),
                      onTap: _checking ? null : _checkUpdate),
                  if (_notice != null && _noticeLocation == 'update')
                    _noticeView(),
                  ListTile(
                      focusNode: _siteDiagnosticFocus,
                      contentPadding: EdgeInsets.zero,
                      leading: const SsrvpnThemeIcon('diagnostic',
                          fallback: Icons.travel_explore),
                      title: const Text('网站访问诊断'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        _siteDiagnosticFocus.requestFocus();
                        showSsrvpnSiteDiagnostic(context, widget.core,
                            onAddRoutingSite:
                                widget.onRoutingSitesChanged == null
                                    ? null
                                    : (host, direct) async {
                                        final sites = addDiagnosticRoutingSite(
                                            widget.settings, host,
                                            direct: direct);
                                        await widget.onRoutingSitesChanged!(
                                            sites, direct);
                                      });
                      }),
                  ListTile(
                      focusNode: _runtimeLogFocus,
                      contentPadding: EdgeInsets.zero,
                      leading: const SsrvpnThemeIcon('logs',
                          fallback: Icons.subject_outlined),
                      title: const Text('运行日志'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        _runtimeLogFocus.requestFocus();
                        showSsrvpnDiagnosticsDialog(context,
                            runDiagnostics: widget.core.runDiagnostics,
                            loadHistory: widget.core.loadDiagnosticHistory,
                            repair: widget.core.repairDiagnosticIssue,
                            onMessage: (message) {
                          if (mounted) _showNotice(message, 'logs');
                        });
                      }),
                  if (_notice != null && _noticeLocation == 'logs')
                    _noticeView(),
                ]),
              ])),
        ]));
  }

  Widget _noticeView() => Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: SsrvpnLiquidSurface(
          key: const Key('settings-notice'),
          radius: 12,
          padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
          child: Row(children: [
            Expanded(
                child: Semantics(
                    liveRegion: true,
                    child: Text(_notice!,
                        style: const TextStyle(fontSize: 14, height: 1.4)))),
            IconButton(
                tooltip: '关闭提示',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => setState(() => _notice = null)),
          ])));

  Widget _section(String title, List<Widget> children,
          {Widget? trailing, Widget? header}) =>
      SsrvpnLiquidSurface(
          padding: const EdgeInsets.all(14),
          child: Material(
              type: MaterialType.transparency,
              child: ListTileTheme(
                  data: ListTileThemeData(
                      minLeadingWidth: 24,
                      horizontalTitleGap: 12,
                      minVerticalPadding: 8,
                      titleTextStyle: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header ??
                            Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 12,
                                runSpacing: 4,
                                children: [
                                  Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (!SsrvpnTheme.of(context)
                                            .isDefault) ...[
                                          SsrvpnThemeIcon(
                                              title == '外观'
                                                  ? 'appearance'
                                                  : 'settings',
                                              fallback:
                                                  Icons.settings_outlined),
                                          const SizedBox(width: 8),
                                        ],
                                        Flexible(
                                            child: Text(title,
                                                style: const TextStyle(
                                                    fontSize: 18,
                                                    fontWeight:
                                                        FontWeight.bold))),
                                      ]),
                                  if (trailing != null) trailing,
                                ]),
                        const SizedBox(height: 10),
                        ...children
                      ]))));
}

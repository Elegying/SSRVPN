import 'ssrvpn_site_diagnostic.dart';
import '../utils/site_routing_suggestion.dart';
import 'dart:io';
import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/app_settings.dart';
import '../services/background_image_store.dart';
import '../services/clash_service_base.dart';
import '../services/update_checker.dart';
import 'ssrvpn_diagnostics_dialog.dart';
import 'ssrvpn_liquid_dialog.dart';
import 'ssrvpn_glass_dialog_route.dart';
import 'ssrvpn_appearance.dart';
import 'ssrvpn_liquid_glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassQuality;

class SsrvpnSettingsPage extends StatefulWidget {
  const SsrvpnSettingsPage(
      {super.key,
      required this.settings,
      required this.core,
      required this.dataDirectory,
      required this.onAppearanceChanged,
      required this.onPortChanged,
      required this.checkForUpdate,
      required this.onUpdateFound,
      this.pickBackgroundImage,
      this.onRoutingSitesChanged});
  final Future<void> Function(List<String> sites, bool direct)?
      onRoutingSitesChanged;
  final Future<XFile?> Function()? pickBackgroundImage;
  final AppSettings settings;
  final ClashServiceBase core;
  final String dataDirectory;
  final Future<void> Function(
      {GlassEffectLevel? glassEffectLevel,
      BackgroundStyle? backgroundStyle,
      String? customBackgroundPath,
      bool? dynamicBackground}) onAppearanceChanged;
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

  Future<void> _save(Future<void> Function() action, String success,
      {String location = 'appearance'}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await action();
      if (mounted) _showNotice(success, location);
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

  Future<void> _pickBackground() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    File? imported;
    bool saved = false;
    try {
      final selected = widget.pickBackgroundImage != null
          ? await widget.pickBackgroundImage!()
          : await openFile(acceptedTypeGroups: const [
              XTypeGroup(
                  label: '背景图片',
                  extensions: ['png', 'jpg', 'jpeg', 'webp'],
                  uniformTypeIdentifiers: ['public.image'])
            ]);
      if (selected == null || !mounted) return;
      imported = await BackgroundImageStore.importImage(
          selected, widget.dataDirectory);
      if (!mounted) return;
      final accepted = await showSsrvpnGlassDialog<bool>(
          context: context,
          builder: (context) => SsrvpnLiquidAlertDialog(
                  title: const Text('背景预览'),
                  content: SizedBox(
                      width: 300,
                      height: 240,
                      child: SsrvpnCustomBackground(path: imported!.path)),
                  actions: [
                    TextButton(
                        onPressed: () =>
                            dismissSsrvpnDialog<bool>(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () =>
                            dismissSsrvpnDialog<bool>(context, true),
                        child: const Text('使用这张背景'))
                  ]));
      if (accepted != true || !mounted) return;
      final oldPath = widget.settings.customBackgroundPath;
      await widget.onAppearanceChanged(
          backgroundStyle: BackgroundStyle.custom,
          customBackgroundPath: imported.path);
      saved = true;
      try {
        await BackgroundImageStore.removeOwned(oldPath, widget.dataDirectory);
      } catch (_) {}
      if (mounted) _showNotice('自定义背景已应用', 'appearance');
    } on FormatException catch (error) {
      if (mounted) _showNotice(error.message, 'appearance');
    } catch (_) {
      if (mounted) _showNotice('图片导入失败，请选择有效的静态图片重试，原背景已保留', 'appearance');
    } finally {
      if (!saved && imported != null) {
        try {
          await BackgroundImageStore.removeOwned(
              imported.path, widget.dataDirectory);
        } catch (_) {}
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = width > 680 ? (width - 640) / 2 : 20.0;
    final selectedLevel = widget.settings.glassEffectLevel ??
        switch (ssrvpnGlassQuality(context)) {
          GlassQuality.minimal => GlassEffectLevel.low,
          GlassQuality.standard => GlassEffectLevel.medium,
          GlassQuality.premium => GlassEffectLevel.high,
        };
    return SafeArea(
        bottom: false,
        child: Column(children: [
          if (_saving) const LinearProgressIndicator(),
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
                _section(
                    '外观',
                    [
                      const Text('液态玻璃特效',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 10, runSpacing: 8, children: [
                        for (final level in GlassEffectLevel.values)
                          ChoiceChip(
                              label: Text(['无', '低', '中', '高'][level.index]),
                              selected: level == selectedLevel,
                              onSelected: _saving
                                  ? null
                                  : (_) => _save(
                                      () => widget.onAppearanceChanged(
                                          glassEffectLevel: level),
                                      '特效档位已保存'))
                      ]),
                      const SizedBox(height: 12),
                      const Text('主题背景',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 12, runSpacing: 12, children: [
                        for (final style in BackgroundStyle.values
                            .where((s) => s != BackgroundStyle.custom))
                          _backgroundChoice(style),
                        OutlinedButton.icon(
                            key: const Key('settings-custom-background'),
                            style: OutlinedButton.styleFrom(
                                minimumSize: const Size(116, 52)),
                            onPressed: _saving ? null : _pickBackground,
                            icon: Icon(widget.settings.backgroundStyle ==
                                    BackgroundStyle.custom
                                ? Icons.check
                                : Icons.add_photo_alternate_outlined),
                            label: const Text('自定义')),
                      ]),
                      if (_notice != null && _noticeLocation == 'appearance')
                        _noticeView(),
                    ],
                    trailing: _backgroundMotionSwitch()),
                const SizedBox(height: 12),
                _section(
                    '代理端口',
                    [
                      Text(
                          widget.core.isRunning
                              ? '当前实际端口：${widget.core.runtimeProxyPort}'
                              : '已保存端口：${widget.settings.proxyPort}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white70)),
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
                                    errorMaxLines: 3,
                                    errorText: _portError),
                                onSubmitted:
                                    _saving ? null : (_) => _savePort()),
                          ),
                        ])),
                const SizedBox(height: 12),
                _section('应用', [
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.rule_folder_outlined),
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
                      leading: const Icon(Icons.system_update_outlined),
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
                      leading: const Icon(Icons.travel_explore),
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
                      leading: const Icon(Icons.subject_outlined),
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
                                  Text(title,
                                      style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold)),
                                  if (trailing != null) trailing,
                                ]),
                        const SizedBox(height: 10),
                        ...children
                      ]))));

  /// Drifting repaints the wallpaper every frame and drags the glass above it
  /// along, so the switch is offered only for the one background that can move.
  Widget _backgroundMotionSwitch() {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final supported =
        widget.settings.backgroundStyle == BackgroundStyle.flowing;
    final interactive = supported && !reducedMotion && !_saving;
    return MergeSemantics(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('动态背景',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(width: 4),
      Switch(
        // Show the switch as off whenever the wallpaper cannot actually move,
        // so the displayed value always matches what the user sees.
        value: supported && !reducedMotion && widget.settings.dynamicBackground,
        onChanged: interactive
            ? (value) => _save(
                () => widget.onAppearanceChanged(dynamicBackground: value),
                value ? '已开启动态背景' : '已关闭动态背景')
            : null,
      ),
    ]));
  }

  Widget _backgroundChoice(BackgroundStyle style) {
    final selected = widget.settings.backgroundStyle == style;
    final label = ssrvpnBackgroundLabel(style);
    return Semantics(
        label: '$label 背景',
        selected: selected,
        button: true,
        child: Tooltip(
            message: label,
            child: InkWell(
                onTap: _saving
                    ? null
                    : () => _save(
                        () =>
                            widget.onAppearanceChanged(backgroundStyle: style),
                        '背景已保存'),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                        color: ssrvpnBackgroundColor(style),
                        gradient: style == BackgroundStyle.flowing
                            ? const LinearGradient(
                                colors: [Color(0xFF163D7D), Color(0xFF691B88)])
                            : null,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: selected ? Colors.white : Colors.white30,
                            width: selected ? 3 : 1)),
                    child: selected
                        ? const Icon(Icons.check, color: Colors.white)
                        : style == BackgroundStyle.flowing
                            ? const Icon(Icons.waves)
                            : null))));
  }
}

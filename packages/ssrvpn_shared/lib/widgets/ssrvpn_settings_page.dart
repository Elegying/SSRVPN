import 'dart:io';
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
      this.pickBackgroundImage});
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
  bool _saving = false;
  bool _checking = false;
  String? _notice;
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
    _port.dispose();
    super.dispose();
  }

  Future<void> _save(Future<void> Function() action, String success) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await action();
      if (mounted) setState(() => _notice = success);
    } catch (_) {
      if (mounted) setState(() => _notice = '保存失败，原设置已保留，请重试');
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
    await _save(() => widget.onPortChanged(value!), '代理端口已保存，下次在应用内连接生效');
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
      setState(() => _notice =
          update == null ? '当前已是最新版本' : '发现新版本 ${update.version}，可点击底部更新入口');
    } catch (error) {
      if (mounted) {
        setState(() => _notice = UpdateChecker.checkFailureMessage(error));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
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
      if (mounted) setState(() => _notice = '自定义背景已保存');
    } on FormatException catch (error) {
      if (mounted) setState(() => _notice = error.message);
    } catch (_) {
      if (mounted) setState(() => _notice = '图片导入失败，请选择有效的静态图片重试，原背景已保留');
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
        child: ListView(
            key: const PageStorageKey('settings-page'),
            padding: EdgeInsets.fromLTRB(horizontalPadding, 24,
                horizontalPadding, MediaQuery.paddingOf(context).bottom + 24),
            children: [
              const Text('设置',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 22),
              _section('外观', [
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
                const SizedBox(height: 20),
                const Text('主题背景',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final style in BackgroundStyle.values
                      .where((s) => s != BackgroundStyle.custom))
                    _backgroundChoice(style)
                ]),
                _backgroundMotionSwitch(),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                      onPressed: _saving ? null : _pickBackground,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(widget.settings.customBackgroundPath.isEmpty
                          ? '添加背景图'
                          : '更换背景图')),
                  if (widget.settings.customBackgroundPath.isNotEmpty)
                    ChoiceChip(
                        label: const Text('自定义'),
                        selected: widget.settings.backgroundStyle ==
                            BackgroundStyle.custom,
                        onSelected: _saving
                            ? null
                            : (_) => _save(
                                () => widget.onAppearanceChanged(
                                    backgroundStyle: BackgroundStyle.custom),
                                '已使用自定义背景')),
                ]),
                const SizedBox(height: 12),
                const Text('支持 JPG、PNG、WebP 静态图片，最大 20 MB。',
                    style: TextStyle(
                        fontSize: 12, height: 1.5, color: Colors.white70)),
              ]),
              const SizedBox(height: 18),
              _section('连接', [
                TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5)
                    ],
                    decoration: InputDecoration(
                        labelText: '代理端口',
                        helperMaxLines: 3,
                        errorMaxLines: 3,
                        helperText: '下次在应用内连接生效',
                        errorText: _portError),
                    onSubmitted: _saving ? null : (_) => _savePort()),
                const SizedBox(height: 12),
                Text(
                    widget.core.isRunning
                        ? '当前实际端口：${widget.core.runtimeProxyPort}'
                        : '已保存端口：${widget.settings.proxyPort}',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white70)),
                const SizedBox(height: 8),
                const Text('连接时检查占用；临时调整不修改已保存端口。其他应用请使用当前实际端口。',
                    style: TextStyle(
                        fontSize: 12, height: 1.5, color: Colors.white70)),
                const SizedBox(height: 10),
                Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                        onPressed: _saving ? null : _savePort,
                        child: const Text('保存端口'))),
              ]),
              const SizedBox(height: 18),
              _section('应用', [
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update_outlined),
                    title: const Text('检查更新'),
                    trailing: _checking
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.chevron_right),
                    onTap: _checking ? null : _checkUpdate),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.subject_outlined),
                    title: const Text('运行日志'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showSsrvpnDiagnosticsDialog(context,
                            runDiagnostics: widget.core.runDiagnostics,
                            loadHistory: widget.core.loadDiagnosticHistory,
                            repair: widget.core.repairDiagnosticIssue,
                            onMessage: (message) {
                          if (mounted) setState(() => _notice = message);
                        })),
              ]),
              if (_saving)
                const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator()),
              if (_notice != null)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Semantics(liveRegion: true, child: Text(_notice!))),
            ]));
  }

  Widget _section(String title, List<Widget> children) => SsrvpnLiquidSurface(
      padding: const EdgeInsets.all(18),
      child: Material(
          type: MaterialType.transparency,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ...children
          ])));

  /// Drifting repaints the wallpaper every frame and drags the glass above it
  /// along, so the switch is offered only for the one background that can move.
  /// Two things can make the switch inert: a background with no movable
  /// wallpaper, and the system "reduce motion" preference. Both are reported
  /// here instead of leaving a toggle that looks on yet cannot be tapped.
  Widget _backgroundMotionSwitch() {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final supported =
        widget.settings.backgroundStyle == BackgroundStyle.flowing;
    final interactive = supported && !reducedMotion && !_saving;
    return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        // Show the switch as off whenever the wallpaper cannot actually move,
        // so the displayed value always matches what the user sees.
        value: supported && !reducedMotion && widget.settings.dynamicBackground,
        onChanged: interactive
            ? (value) => _save(
                () => widget.onAppearanceChanged(dynamicBackground: value),
                value ? '已开启动态背景' : '已关闭动态背景')
            : null,
        secondary: const Icon(Icons.motion_photos_on_outlined),
        title:
            const Text('动态背景', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
            !supported
                ? '仅「壁纸」背景支持动态效果'
                : reducedMotion
                    ? '系统已开启「减少动态效果」，壁纸将保持静止'
                    : '壁纸缓慢流动。关闭后画面静止，可明显降低 GPU 与电量占用',
            style: const TextStyle(fontSize: 12, height: 1.5)));
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

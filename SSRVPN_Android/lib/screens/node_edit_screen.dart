import '../utils/responsive.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:ssrvpn_shared/models/proxy_node.dart';
import '../services/settings_service.dart';
import '../services/subscription_service.dart';
import '../theme/app_theme.dart';

class NodeEditScreen extends StatefulWidget {
  final ProxyNode node;

  const NodeEditScreen({super.key, required this.node});

  @override
  State<NodeEditScreen> createState() => _NodeEditScreenState();
}

class _NodeEditScreenState extends State<NodeEditScreen> {
  late ProxyNode _editNode;
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  late String _type;
  late final TextEditingController _extraController;
  bool _saving = false;

  static const _types = [
    'ss',
    'ssr',
    'vmess',
    'vless',
    'trojan',
    'anytls',
    'socks5',
    'http'
  ];
  static const _commonKeys = {
    'name',
    'type',
    'server',
    'port',
    'password',
    'cipher',
    'protocol',
    'protocol-param',
    'obfs',
    'obfs-param',
    'uuid',
    'alterId',
    'network',
    'sni',
    'servername',
    'flow',
  };

  @override
  void initState() {
    super.initState();
    _editNode = widget.node;
    final config = widget.node.extra;
    _type = widget.node.type;
    _controllers = {
      'name': TextEditingController(text: widget.node.name),
      'server': TextEditingController(text: widget.node.server),
      'port': TextEditingController(text: widget.node.port.toString()),
      for (final key in _commonKeys
          .where((key) => !{'name', 'type', 'server', 'port'}.contains(key)))
        key: TextEditingController(text: config[key]?.toString() ?? ''),
    };
    final extras = <String, dynamic>{
      for (final entry in config.entries)
        if (!_commonKeys.contains(entry.key)) entry.key: entry.value,
    };
    _extraController = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(extras),
    );
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _extraController.dispose();
    super.dispose();
  }

  bool _hasField(String key, Set<String> types) =>
      types.contains(_type) || _editNode.extra.containsKey(key);

  Widget _field(
    String key,
    String label, {
    bool required = false,
    bool secret = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Padding(
      padding:  EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: _controllers[key],
        obscureText: secret,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(labelText: label),
        validator: required
            ? (value) =>
                value == null || value.trim().isEmpty ? '请输入$label' : null
            : null,
      ),
    );
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final port = int.tryParse(_controllers['port']!.text.trim());
    if (port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text('端口必须是 1-65535 之间的数字'),
        ),
      );
      return;
    }

    Map<String, dynamic> extras;
    try {
      final decoded = jsonDecode(
          _extraController.text.trim().isEmpty ? '{}' : _extraController.text);
      if (decoded is! Map) throw const FormatException();
      extras = Map<String, dynamic>.from(decoded);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text('其他参数必须是有效的 JSON 对象'),
        ),
      );
      return;
    }

    final result = <String, dynamic>{
      ...extras,
      'name': _controllers['name']!.text.trim(),
      'type': _type,
      'server': _controllers['server']!.text.trim(),
      'port': port,
    };
    for (final key in _commonKeys) {
      if ({'name', 'type', 'server', 'port'}.contains(key)) continue;
      final value = _controllers[key]!.text.trim();
      if (value.isNotEmpty) {
        result[key] = key == 'alterId' ? int.tryParse(value) ?? value : value;
      }
    }

    final originalName = _editNode.name;
    final newName = result['name'] as String;
    final settingsService = context.read<SettingsService>();
    final subscriptionService = context.read<SubscriptionService>();
    final renameRemembered =
        originalName != newName && settingsService.settings.lastSelectedNodeName == originalName;

    setState(() => _saving = true);
    try {
      if (renameRemembered) {
        await settingsService.renameLastSelectedNode(originalName, newName);
      }
      await subscriptionService.updateNode(originalName, result);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (renameRemembered) {
        await settingsService.renameLastSelectedNode(newName, originalName);
      }
      if (mounted) {
        setState(() => _saving = false);
        final msg = e.toString();
        final friendlyMsg = msg.contains('备注名已存在')
            ? '节点名称重复，请使用不同的名称'
            : msg.contains('找不到')
            ? '节点已被删除，请返回刷新'
            : '保存失败，请稍后重试';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            margin:  EdgeInsets.fromLTRB(16, 0, 16, 88),
            content: Text(friendlyMsg),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title:  Text('编辑节点'),
        actions: [
          Padding(
            padding:  EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ?  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  :  Icon(Icons.save_rounded, size: 18),
              label:  Text('保存',
                  style: TextStyle(
                      color: AppTheme.primaryColor, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding:  EdgeInsets.all(20),
          children: [
            Text(
              '修改仅保存在本地，刷新订阅后会被订阅内容覆盖。',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
             SizedBox(height: 20),
            _field('name', '备注名', required: true),
            _field('server', '服务器地址', required: true),
            _field(
              'port',
              '端口',
              required: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            Padding(
              padding:  EdgeInsets.only(bottom: 14),
              child: DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: '节点类型'),
                items: ({..._types, _type}.toList()..sort())
                    .map((type) =>
                        DropdownMenuItem(value: type, child: Text(type)))
                    .toList(),
                onChanged: (value) => setState(() => _type = value ?? _type),
              ),
            ),
            if (_hasField('password', {'ss', 'ssr', 'trojan', 'anytls'}))
              _field('password', '密码', secret: true),
            if (_hasField('cipher', {'ss', 'ssr'})) _field('cipher', '加密方式'),
            if (_hasField('protocol', {'ssr'})) _field('protocol', '协议'),
            if (_hasField('protocol-param', {'ssr'}))
              _field('protocol-param', '协议参数'),
            if (_hasField('obfs', {'ssr'})) _field('obfs', '混淆'),
            if (_hasField('obfs-param', {'ssr'})) _field('obfs-param', '混淆参数'),
            if (_hasField('uuid', {'vmess', 'vless'})) _field('uuid', 'UUID'),
            if (_hasField('alterId', {'vmess'}))
              _field(
                'alterId',
                'Alter ID',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            if (_hasField('network', {'vmess', 'vless', 'trojan'}))
              _field('network', '传输协议'),
            if (_hasField('flow', {'vless'})) _field('flow', 'Flow'),
            if (_hasField('sni', {'vmess', 'vless', 'trojan', 'anytls'}))
              _field('sni', 'SNI'),
            if (_hasField('servername', {}))
              _field('servername', 'Server Name'),
             SizedBox(height: 4),
            TextFormField(
              controller: _extraController,
              minLines: 5,
              maxLines: 12,
              style: TextStyle(fontFamily: 'monospace', fontSize: Responsive.sp(12)),
              decoration: const InputDecoration(
                labelText: '其他参数（JSON）',
                alignLabelWithHint: true,
                helperText: 'TLS、插件、WebSocket 等未列出的参数可在这里修改',
              ),
            ),
             SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _save,
                child:  Text('保存修改'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

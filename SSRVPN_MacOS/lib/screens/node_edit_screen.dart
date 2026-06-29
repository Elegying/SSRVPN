import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:ssrvpn_shared/models/proxy_node.dart';
import '../services/settings_service.dart';
import '../services/subscription_service.dart';
import '../theme/app_theme.dart';

class NodeEditScreen extends StatefulWidget {
  const NodeEditScreen({super.key, required this.node});

  final ProxyNode node;

  @override
  State<NodeEditScreen> createState() => _NodeEditScreenState();
}

class _NodeEditScreenState extends State<NodeEditScreen> {
  late ProxyNode _editNode;
  static const _standardTypes = [
    'ss',
    'ssr',
    'vmess',
    'vless',
    'trojan',
    'anytls',
  ];
  static const _editableKeys = {
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
    'alter-id',
    'network',
    'sni',
    'servername',
    'flow',
  };

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _serverController;
  late final TextEditingController _portController;
  late final TextEditingController _passwordController;
  late final TextEditingController _cipherController;
  late final TextEditingController _protocolController;
  late final TextEditingController _protocolParamController;
  late final TextEditingController _obfsController;
  late final TextEditingController _obfsParamController;
  late final TextEditingController _uuidController;
  late final TextEditingController _alterIdController;
  late final TextEditingController _networkController;
  late final TextEditingController _sniController;
  late final TextEditingController _flowController;
  late final TextEditingController _advancedController;

  late String _type;
  bool _saving = false;
  bool _obscurePassword = true;

  Map<String, dynamic> get _originalConfig =>
      Map<String, dynamic>.from(widget.node.extra);

  @override
  void initState() {
    super.initState();
    _editNode = widget.node;
    final config = _originalConfig;
    _type = (config['type']?.toString() ?? widget.node.type).toLowerCase();
    _nameController = _controller(config['name'] ?? widget.node.name);
    _serverController = _controller(config['server'] ?? widget.node.server);
    _portController = _controller(config['port'] ?? widget.node.port);
    _passwordController = _controller(config['password']);
    _cipherController = _controller(config['cipher']);
    _protocolController = _controller(config['protocol']);
    _protocolParamController = _controller(config['protocol-param']);
    _obfsController = _controller(config['obfs']);
    _obfsParamController = _controller(config['obfs-param']);
    _uuidController = _controller(config['uuid']);
    _alterIdController =
        _controller(config['alterId'] ?? config['alter-id'] ?? 0);
    _networkController = _controller(config['network'] ?? 'tcp');
    _sniController = _controller(config['servername'] ?? config['sni']);
    _flowController = _controller(config['flow']);

    final advanced = <String, dynamic>{};
    for (final entry in config.entries) {
      if (!_editableKeys.contains(entry.key)) {
        advanced[entry.key] = entry.value;
      }
    }
    _advancedController = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(advanced),
    );
  }

  TextEditingController _controller(Object? value) =>
      TextEditingController(text: value?.toString() ?? '');

  @override
  void dispose() {
    for (final controller in [
      _nameController,
      _serverController,
      _portController,
      _passwordController,
      _cipherController,
      _protocolController,
      _protocolParamController,
      _obfsController,
      _obfsParamController,
      _uuidController,
      _alterIdController,
      _networkController,
      _sniController,
      _flowController,
      _advancedController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> get _availableTypes {
    final values = <String>{..._standardTypes, _type};
    return values.toList();
  }

  bool get _usesPassword => {'ss', 'ssr', 'trojan', 'anytls'}.contains(_type);
  bool get _usesCipher => {'ss', 'ssr', 'vmess'}.contains(_type);
  bool get _usesSsr => _type == 'ssr';
  bool get _usesUuid => {'vmess', 'vless'}.contains(_type);
  bool get _usesAlterId => _type == 'vmess';
  bool get _usesTransport => {'vmess', 'vless', 'trojan'}.contains(_type);
  bool get _usesSni => {'vmess', 'vless', 'trojan', 'anytls'}.contains(_type);
  bool get _usesFlow => _type == 'vless';

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;

    Map<String, dynamic> advanced;
    try {
      final decoded = jsonDecode(_advancedController.text.trim());
      if (decoded is! Map) {
        throw const FormatException('必须是 JSON 对象');
      }
      advanced = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    } on FormatException catch (e) {
      _showError('其他参数 JSON 格式错误：${e.message}');
      return;
    }

    final config = <String, dynamic>{...advanced};
    config['name'] = _nameController.text.trim();
    config['type'] = _type;
    config['server'] = _serverController.text.trim();
    config['port'] = int.parse(_portController.text.trim());

    if (_usesPassword) config['password'] = _passwordController.text;
    if (_usesCipher) config['cipher'] = _cipherController.text.trim();
    if (_usesSsr) {
      config['protocol'] = _protocolController.text.trim();
      _putOptional(
        config,
        'protocol-param',
        _protocolParamController.text.trim(),
      );
      config['obfs'] = _obfsController.text.trim();
      _putOptional(config, 'obfs-param', _obfsParamController.text.trim());
    }
    if (_usesUuid) config['uuid'] = _uuidController.text.trim();
    if (_usesAlterId) {
      config['alterId'] = int.tryParse(_alterIdController.text.trim()) ?? 0;
    }
    if (_usesTransport) {
      _putOptional(config, 'network', _networkController.text.trim());
    }
    if (_usesSni) {
      final sniKey =
          _type == 'trojan' || _type == 'anytls' ? 'sni' : 'servername';
      _putOptional(config, sniKey, _sniController.text.trim());
    }
    if (_usesFlow) {
      _putOptional(config, 'flow', _flowController.text.trim());
    }

    final subscriptionService = context.read<SubscriptionService>();
    setState(() => _saving = true);
    final originalName = _editNode.name;
    final updatedName = _nameController.text.trim();
    final settingsService = context.read<SettingsService>();
    final renameRememberedNode = originalName != updatedName &&
        settingsService.settings.lastSelectedNodeName == originalName;
    try {
      if (renameRememberedNode) {
        await settingsService.renameLastSelectedNode(
          originalName,
          updatedName,
        );
      }
      await subscriptionService.updateNode(originalName, config);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (renameRememberedNode) {
        await settingsService.renameLastSelectedNode(
          updatedName,
          originalName,
        );
      }
      if (mounted) {
        setState(() => _saving = false);
        _showError(_readableError(e));
      }
    }
  }

  void _putOptional(
    Map<String, dynamic> config,
    String key,
    String value,
  ) {
    if (value.isNotEmpty) config[key] = value;
  }

  String _readableError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        content: Text('保存失败：$message'),
        backgroundColor: AppTheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background =
        isDark ? const Color(0xFF0B0D14) : const Color(0xFFF8FAFC);
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        title: const Text('编辑节点'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: TextButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded, size: 18),
              label: const Text('保存'),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            _buildNotice(isDark),
            const SizedBox(height: 20),
            _buildSection(
              title: '基本信息',
              isDark: isDark,
              children: [
                _field(
                  controller: _nameController,
                  label: '节点备注名',
                  validator: _required('节点备注名不能为空'),
                ),
                _field(
                  controller: _serverController,
                  label: '服务器地址',
                  validator: _required('服务器地址不能为空'),
                ),
                _field(
                  controller: _portController,
                  label: '端口',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (value) {
                    final port = int.tryParse(value?.trim() ?? '');
                    if (port == null || port < 1 || port > 65535) {
                      return '端口必须在 1-65535 之间';
                    }
                    return null;
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: '节点类型'),
                  items: [
                    for (final type in _availableTypes)
                      DropdownMenuItem(
                        value: type,
                        child: Text(type.toUpperCase()),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _type = value);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSection(
              title: '${_type.toUpperCase()} 参数',
              isDark: isDark,
              children: [
                if (_usesPassword)
                  _field(
                    controller: _passwordController,
                    label: '密码',
                    obscureText: _obscurePassword,
                    suffixIcon: IconButton(
                      onPressed: () => setState(
                        () => _obscurePassword = !_obscurePassword,
                      ),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                if (_usesCipher)
                  _field(
                    controller: _cipherController,
                    label: '加密方式',
                  ),
                if (_usesSsr) ...[
                  _field(
                    controller: _protocolController,
                    label: 'SSR 协议',
                  ),
                  _field(
                    controller: _protocolParamController,
                    label: '协议参数',
                  ),
                  _field(controller: _obfsController, label: '混淆'),
                  _field(
                    controller: _obfsParamController,
                    label: '混淆参数',
                  ),
                ],
                if (_usesUuid)
                  _field(
                    controller: _uuidController,
                    label: 'UUID',
                  ),
                if (_usesAlterId)
                  _field(
                    controller: _alterIdController,
                    label: 'Alter ID',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                if (_usesTransport)
                  _field(
                    controller: _networkController,
                    label: '传输协议',
                    hint: '例如 tcp、ws、grpc',
                  ),
                if (_usesSni)
                  _field(
                    controller: _sniController,
                    label: 'SNI',
                  ),
                if (_usesFlow)
                  _field(
                    controller: _flowController,
                    label: 'Flow',
                  ),
                if (!_usesPassword &&
                    !_usesCipher &&
                    !_usesSsr &&
                    !_usesUuid &&
                    !_usesTransport)
                  const Text('该类型的参数可在下方 JSON 中编辑。'),
              ],
            ),
            const SizedBox(height: 16),
            _buildSection(
              title: '其他参数（JSON）',
              isDark: isDark,
              children: [
                Text(
                  '这里保留 TLS、WebSocket、plugin-opts 等高级参数。'
                  '内容必须是 JSON 对象。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _field(
                  controller: _advancedController,
                  label: '高级参数',
                  minLines: 8,
                  maxLines: 18,
                  keyboardType: TextInputType.multiline,
                  textStyle: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotice(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: (isDark ? 22 : 16) / 255),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 70 / 255)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppTheme.warning,
            size: 20,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '修改仅保存在本地，刷新订阅后会被订阅内容覆盖。',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required bool isDark,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? AppTheme.border : AppTheme.lightBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1) const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    bool obscureText = false,
    Widget? suffixIcon,
    int? minLines = 1,
    int? maxLines = 1,
    TextStyle? textStyle,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffixIcon,
        alignLabelWithHint: (maxLines ?? 1) > 1,
      ),
      validator: validator,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      obscureText: obscureText,
      minLines: obscureText ? 1 : minLines,
      maxLines: obscureText ? 1 : maxLines,
      style: textStyle,
    );
  }

  String? Function(String?) _required(String message) {
    return (value) => value == null || value.trim().isEmpty ? message : null;
  }
}

part of desktop_home_screen;

class _DesktopForceProxySitesDialog extends StatefulWidget {
  const _DesktopForceProxySitesDialog({
    required this.savedSites,
    this.forceDirect = false,
  });

  final List<String> savedSites;
  final bool forceDirect;

  static Future<List<String>?> show(
    BuildContext context, {
    required List<String> savedSites,
    bool forceDirect = false,
  }) {
    return showSsrvpnGlassDialog<List<String>>(
      context: context,
      builder: (_) => _DesktopForceProxySitesDialog(
        savedSites: savedSites,
        forceDirect: forceDirect,
      ),
    );
  }

  @override
  State<_DesktopForceProxySitesDialog> createState() =>
      _DesktopForceProxySitesDialogState();
}

class _DesktopForceProxySitesDialogState
    extends State<_DesktopForceProxySitesDialog> {
  late final List<TextEditingController> _controllers;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final savedSites = AppSettings.normalizeForceProxySites(widget.savedSites);
    _controllers = List.generate(
      AppSettings.forceProxySiteLimit,
      (index) => TextEditingController(text: savedSites[index]),
    );
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values =
        _controllers.map((controller) => controller.text.trim()).toList();
    for (var i = 0; i < values.length; i++) {
      final message = _validateSite(values[i]);
      if (message != null) {
        setState(() => _errorText = '第 ${i + 1} 个输入框：$message');
        return;
      }
    }
    dismissSsrvpnDialog<List<String>>(context, values);
  }

  String? _validateSite(String value) {
    if (value.trim().isEmpty) return null;
    if (RegExp(r'[\s,，;；]').hasMatch(value.trim())) {
      return '一个输入框只能填写一个网址';
    }
    final host = AppSettings.extractForceProxyHost(value);
    if (host == null) {
      return '请输入有效的网址或域名';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark
        ? SsrvpnTheme.of(context).textPrimary
        : SsrvpnTheme.of(context).textPrimary;
    final subtitleColor = isDark
        ? SsrvpnTheme.of(context).textSecondary
        : SsrvpnTheme.of(context).textSecondary;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460),
        child: SsrvpnModalGlassPanel(
          borderRadius: 16,
          opaque: true,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              SsrvpnTheme.of(context).primary,
                              SsrvpnTheme.of(context).accent
                            ],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          widget.forceDirect
                              ? Icons.link_off_rounded
                              : Icons.add_link_rounded,
                          color: SsrvpnTheme.of(context).onPrimary,
                          size: 22,
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.forceDirect ? '添加强制直连网站' : '添加强制代理网站',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  Text(
                    widget.forceDirect
                        ? '仅在确认网站无需节点时使用。同一网站以后保存的方向为准；父域与子域冲突时代理优先：'
                        : '默认规则已涵盖绝大部分网站，如出现个别网站无法访问的情况，再使用此功能，粘贴需要强制代理的网址：',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: subtitleColor,
                    ),
                  ),
                  SizedBox(height: 14),
                  for (var i = 0; i < AppSettings.forceProxySiteLimit; i++) ...[
                    TextField(
                      controller: _controllers[i],
                      maxLines: 1,
                      keyboardType: TextInputType.url,
                      textInputAction: i == AppSettings.forceProxySiteLimit - 1
                          ? TextInputAction.done
                          : TextInputAction.next,
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
                      ],
                      decoration: GlassInputDecoration(
                        primary: SsrvpnTheme.of(context).primary,
                        isDark: isDark,
                        labelText: '网址 ${i + 1}',
                        hintText: 'https://example.com',
                        prefixIcon: Icon(Icons.language, size: 18),
                      ).copyWith(
                        labelStyle: TextStyle(color: subtitleColor),
                        hintStyle: TextStyle(color: subtitleColor),
                      ),
                      onSubmitted: (_) {
                        if (i == AppSettings.forceProxySiteLimit - 1) {
                          _submit();
                        }
                      },
                    ),
                    if (i != AppSettings.forceProxySiteLimit - 1)
                      SizedBox(height: 10),
                  ],
                  if (_errorText != null) ...[
                    SizedBox(height: 12),
                    Text(
                      _errorText!,
                      style: TextStyle(
                          color: SsrvpnTheme.of(context).error, fontSize: 12),
                    ),
                  ],
                  SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () =>
                              dismissSsrvpnDialog<List<String>>(context),
                          child: Text('取消'),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: SsrvpnTheme.of(context).primary,
                            foregroundColor: SsrvpnTheme.of(context).onPrimary,
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text('确定'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

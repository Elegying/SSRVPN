part of desktop_home_screen;

class _DesktopForceProxySitesDialog extends StatefulWidget {
  const _DesktopForceProxySitesDialog({required this.savedSites});

  final List<String> savedSites;

  static Future<List<String>?> show(
    BuildContext context, {
    required List<String> savedSites,
  }) {
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _DesktopForceProxySitesDialog(savedSites: savedSites),
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
    _controllers = List.generate(
      AppSettings.forceProxySiteLimit,
      (index) => TextEditingController(text: widget.savedSites[index]),
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
    Navigator.of(context).pop(values);
  }

  String? _validateSite(String value) {
    if (value.trim().isEmpty) return null;
    if (RegExp(r'[\s,，;；]').hasMatch(value.trim())) {
      return '一个输入框只能填写一个网址';
    }
    if (AppSettings.extractForceProxyHost(value) == null) {
      return '请输入有效的网址或域名';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subtitleColor =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
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
                        gradient: const LinearGradient(
                          colors: [
                            AppTheme.primary,
                            AppTheme.accentColor,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.add_link_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '添加强制代理网站',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: titleColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '默认规则已涵盖绝大部分网站，如出现个别网站无法访问的情况，再使用此功能，粘贴需要强制代理的网址：',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: subtitleColor,
                  ),
                ),
                const SizedBox(height: 14),
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
                      isDark: isDark,
                      labelText: '网址 ${i + 1}',
                      hintText: 'https://example.com',
                      prefixIcon: const Icon(Icons.language, size: 18),
                    ),
                    onSubmitted: (_) {
                      if (i == AppSettings.forceProxySiteLimit - 1) {
                        _submit();
                      }
                    },
                  ),
                  if (i != AppSettings.forceProxySiteLimit - 1)
                    const SizedBox(height: 10),
                ],
                if (_errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorText!,
                    style: const TextStyle(
                      color: AppTheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('确定'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

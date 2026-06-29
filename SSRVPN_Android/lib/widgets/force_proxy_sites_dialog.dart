import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/app_settings.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/glass_container.dart';

/// 强制代理网站配置对话框
///
/// 独立 StatefulWidget，内部管理验证逻辑与表单状态。
/// 通过 [show] 静态方法弹出，返回用户提交的站点列表，返回 null 表示取消。
class ForceProxySitesDialog extends StatefulWidget {
  final List<String> savedSites;

  const ForceProxySitesDialog({super.key, required this.savedSites});

  /// 弹出对话框，返回用户确认的站点列表（null 表示取消）
  static Future<List<String>?> show(
    BuildContext context, {
    required List<String> savedSites,
  }) {
    return showDialog<List<String>>(
      context: context,
      builder: (_) => ForceProxySitesDialog(savedSites: savedSites),
    );
  }

  @override
  State<ForceProxySitesDialog> createState() => _ForceProxySitesDialogState();
}

class _ForceProxySitesDialogState extends State<ForceProxySitesDialog> {
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
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = _controllers.map((c) => c.text.trim()).toList();
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
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: GlassContainer(
        borderRadius: 16,
        enableShadow: true,
        enablePress: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题行
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              AppTheme.primaryColor,
                              AppTheme.accentColor
                            ],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.add_link_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '添加强制代理网站',
                          style: TextStyle(
                            fontSize: Responsive.sp(18),
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
                      fontSize: Responsive.sp(13),
                      height: 1.45,
                      color: subColor,
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 输入框列表
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
                  // 错误提示
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorText!,
                      style: TextStyle(
                        color: AppTheme.errorColor,
                        fontSize: Responsive.sp(12),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  // 按钮行
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
                            backgroundColor: AppTheme.primaryColor,
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
      ),
    );
  }
}

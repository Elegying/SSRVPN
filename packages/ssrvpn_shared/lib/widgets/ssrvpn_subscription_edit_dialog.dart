import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/subscription.dart';
import 'ssrvpn_app_surface.dart';

class SsrvpnSubscriptionEditDraft {
  const SsrvpnSubscriptionEditDraft({required this.name, required this.url});

  final String name;
  final String url;
}

Future<SsrvpnSubscriptionEditDraft?> showSsrvpnSubscriptionEditDialog(
  BuildContext context,
  Subscription subscription,
) {
  return showDialog<SsrvpnSubscriptionEditDraft>(
    context: context,
    builder: (dialogContext) =>
        _SubscriptionEditDialog(subscription: subscription),
  );
}

class _SubscriptionEditDialog extends StatefulWidget {
  const _SubscriptionEditDialog({required this.subscription});

  final Subscription subscription;

  @override
  State<_SubscriptionEditDialog> createState() =>
      _SubscriptionEditDialogState();
}

class _SubscriptionEditDialogState extends State<_SubscriptionEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.subscription.name);
    _urlController = TextEditingController(text: widget.subscription.url);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      SsrvpnSubscriptionEditDraft(
        name: _nameController.text.trim(),
        url: _urlController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight = (MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).vertical -
            48)
        .clamp(220.0, double.infinity);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SsrvpnFrostedPanel(
        key: const Key('ssrvpn-subscription-edit-glass'),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 440,
            maxHeight: availableHeight,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Icon(Icons.edit_rounded, color: SsrvpnUiTokens.primary),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '编辑订阅',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        TextFormField(
                          key: const Key('ssrvpn-subscription-edit-name'),
                          controller: _nameController,
                          autofocus: true,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(128),
                          ],
                          decoration: const InputDecoration(
                            labelText: '订阅名称',
                            hintText: '输入便于识别的名称',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                                  ? '订阅名称不能为空'
                                  : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          key: const Key('ssrvpn-subscription-edit-url'),
                          controller: _urlController,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.done,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLines: 3,
                          minLines: 1,
                          decoration: const InputDecoration(
                            labelText: '订阅链接',
                            hintText: '建议使用 HTTPS；也支持 HTTP 或节点链接',
                            prefixIcon: Icon(Icons.link_rounded),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                                  ? '订阅链接不能为空'
                                  : null,
                          onFieldSubmitted: (_) => _save(),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('ssrvpn-subscription-edit-save'),
                        onPressed: _save,
                        child: const Text('保存'),
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

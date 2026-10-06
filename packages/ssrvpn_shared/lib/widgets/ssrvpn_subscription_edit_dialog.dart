import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';
import 'ssrvpn_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/subscription.dart';
import 'ssrvpn_app_surface.dart';

final _openSubscriptionEditors = Expando<bool>('ssrvpn subscription editor');

class SsrvpnSubscriptionEditDraft {
  const SsrvpnSubscriptionEditDraft(
      {required this.name, required this.url, this.refreshViaProxy = false});

  final String name;
  final String url;
  final bool refreshViaProxy;
}

Future<SsrvpnSubscriptionEditDraft?> showSsrvpnSubscriptionEditDialog(
  BuildContext context,
  Subscription subscription,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (_openSubscriptionEditors[navigator] == true) return null;
  _openSubscriptionEditors[navigator] = true;
  try {
    return await showSsrvpnGlassDialog<SsrvpnSubscriptionEditDraft>(
      context: context,
      builder: (dialogContext) =>
          _SubscriptionEditDialog(subscription: subscription),
    );
  } finally {
    _openSubscriptionEditors[navigator] = false;
  }
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
  late bool _refreshViaProxy;
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _refreshViaProxy = widget.subscription.refreshViaProxy;
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
    dismissSsrvpnDialog<SsrvpnSubscriptionEditDraft>(
      context,
      SsrvpnSubscriptionEditDraft(
        name: _nameController.text.trim(),
        url: _urlController.text.trim(),
        refreshViaProxy: _refreshViaProxy,
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
      insetPadding: EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SsrvpnModalGlassPanel(
        padding: EdgeInsets.all(24),
        key: Key('ssrvpn-subscription-edit-glass'),
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
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.edit_rounded,
                                color: SsrvpnUiTokens.of(context).primary),
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
                        SizedBox(height: 18),
                        SsrvpnLiquidField(
                            label: '订阅名称',
                            child: TextFormField(
                              key: Key('ssrvpn-subscription-edit-name'),
                              controller: _nameController,
                              autofocus: true,
                              textInputAction: TextInputAction.next,
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(128),
                              ],
                              decoration: InputDecoration(
                                hintText: '输入便于识别的名称',
                                prefixIcon: Icon(Icons.badge_outlined),
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                      ? '订阅名称不能为空'
                                      : null,
                            )),
                        SizedBox(height: 14),
                        SsrvpnLiquidField(
                            label: '订阅链接',
                            child: TextFormField(
                              key: Key('ssrvpn-subscription-edit-url'),
                              controller: _urlController,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.done,
                              autocorrect: false,
                              enableSuggestions: true,
                              enableIMEPersonalizedLearning: false,
                              maxLines: 3,
                              minLines: 1,
                              decoration: InputDecoration(
                                hintText: '建议使用 HTTPS；也支持 HTTP 或节点链接',
                                prefixIcon: Icon(Icons.link_rounded),
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                      ? '订阅链接不能为空'
                                      : null,
                              onFieldSubmitted: (_) => _save(),
                            )),
                        Material(
                            type: MaterialType.transparency,
                            child: SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('通过已连接的节点更新'),
                                subtitle: const Text(
                                    '用于手动和自动更新。开启后需先连接节点；关闭时沿用直连请求方式。单节点链接不受此设置影响。'),
                                value: _refreshViaProxy,
                                onChanged: (value) =>
                                    setState(() => _refreshViaProxy = value))),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () =>
                            dismissSsrvpnDialog<SsrvpnSubscriptionEditDraft>(
                                context),
                        child: Text('取消'),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: Key('ssrvpn-subscription-edit-save'),
                        onPressed: _save,
                        child: Text('保存'),
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

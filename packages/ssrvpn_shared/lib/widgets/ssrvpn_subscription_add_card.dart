part of 'ssrvpn_subscription_view.dart';

class _SubscriptionAddCard extends StatelessWidget {
  const _SubscriptionAddCard({
    required this.urlController,
    required this.inputFocusNode,
    required this.addActionKey,
    required this.isAdding,
    required this.isBusy,
    required this.onAdd,
    this.pickQrImage,
  });

  final TextEditingController urlController;
  final FocusNode inputFocusNode;
  final GlobalKey addActionKey;
  final bool isAdding;
  final bool isBusy;
  final VoidCallback onAdd;
  final Future<XFile?> Function()? pickQrImage;

  @override
  Widget build(BuildContext context) {
    return SsrvpnSurfaceCard(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SsrvpnThemeIcon(
                'add',
                fallback: Icons.add_circle_outline_rounded,
                color: SsrvpnUiTokens.of(context).accent,
                size: 24,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '添加订阅',
                  style: TextStyle(
                    color: SsrvpnUiTokens.of(context).textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SsrvpnQrImportButton(
                enabled: !isBusy,
                controller: urlController,
                onAdd: onAdd,
                pickImage: pickQrImage,
              ),
            ],
          ),
          SizedBox(height: 10),
          SsrvpnLiquidField(
              child: TextField(
            key: Key('ssrvpn-subscription-input'),
            controller: urlController,
            focusNode: inputFocusNode,
            enabled: !isBusy,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: true,
            enableIMEPersonalizedLearning: false,
            scrollPadding: EdgeInsets.fromLTRB(20, 20, 20, 120),
            onSubmitted: isBusy ? null : (_) => onAdd(),
            decoration: InputDecoration(
              hintText: '粘贴订阅或节点链接',
              prefixIcon: Icon(Icons.link_rounded),
              filled: true,
              fillColor: Colors.transparent,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide:
                    BorderSide(color: SsrvpnUiTokens.of(context).border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide:
                    BorderSide(color: SsrvpnUiTokens.of(context).border),
              ),
            ),
          )),
          SizedBox(height: 10),
          ConstrainedBox(
            key: addActionKey,
            constraints: BoxConstraints(minHeight: 48),
            child: SizedBox(
              width: double.infinity,
              child: SsrvpnLiquidSurface(
                  radius: 16,
                  dense: true,
                  child: FilledButton(
                    key: Key('ssrvpn-subscription-add'),
                    onPressed: isBusy ? null : onAdd,
                    style: FilledButton.styleFrom(
                      backgroundColor: SsrvpnUiTokens.of(context).primary,
                      foregroundColor: SsrvpnUiTokens.of(context).onPrimary,
                      disabledBackgroundColor: SsrvpnUiTokens.of(context)
                          .primaryBlue
                          .withValues(alpha: 0.42),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    child: isAdding
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              semanticsLabel: '正在添加订阅',
                              strokeWidth: 2,
                              color: SsrvpnUiTokens.of(context).onPrimary,
                            ),
                          )
                        : Text(
                            '添加',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  )),
            ),
          ),
        ],
      ),
    );
  }
}

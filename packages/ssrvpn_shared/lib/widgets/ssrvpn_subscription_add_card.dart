part of 'ssrvpn_subscription_view.dart';

class _SubscriptionAddCard extends StatelessWidget {
  const _SubscriptionAddCard({
    required this.urlController,
    required this.inputFocusNode,
    required this.addActionKey,
    required this.isAdding,
    required this.isBusy,
    required this.onAdd,
  });

  final TextEditingController urlController;
  final FocusNode inputFocusNode;
  final GlobalKey addActionKey;
  final bool isAdding;
  final bool isBusy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SsrvpnSurfaceCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.add_circle_outline_rounded,
                color: SsrvpnUiTokens.accent,
                size: 24,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '添加订阅',
                  style: TextStyle(
                    color: SsrvpnUiTokens.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            key: const Key('ssrvpn-subscription-input'),
            controller: urlController,
            focusNode: inputFocusNode,
            enabled: !isBusy,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
            onSubmitted: isBusy ? null : (_) => onAdd(),
            decoration: InputDecoration(
              hintText: '粘贴订阅或节点链接',
              prefixIcon: const Icon(Icons.link_rounded),
              filled: true,
              fillColor: const Color(0xFF181B2A),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 17,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: SsrvpnUiTokens.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: SsrvpnUiTokens.border),
              ),
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            key: addActionKey,
            constraints: const BoxConstraints(minHeight: 52),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('ssrvpn-subscription-add'),
                onPressed: isBusy ? null : onAdd,
                style: FilledButton.styleFrom(
                  backgroundColor: SsrvpnUiTokens.primaryBlue,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      SsrvpnUiTokens.primaryBlue.withValues(alpha: 0.42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                child: isAdding
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        '添加',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

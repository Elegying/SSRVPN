part of desktop_home_screen;

extension _DesktopHomeInitialSubscriptionActions on _HomeScreenState {
  void _maybeShowInitialSubscriptionDialog(SubscriptionService subService) {
    final nodes = HomeNodeController.runnableNodesFrom(subService.allNodes);
    if (_initialSubscriptionDialogInFlight || nodes.isNotEmpty) {
      return;
    }
    if (_lastEmptySubscriptionPromptRevision == subService.revision) return;
    _lastEmptySubscriptionPromptRevision = subService.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canUpdateUi) unawaited(_showInitialSubscriptionDialog());
    });
  }

  String? _validateSubscriptionInput(
    String input,
    SubscriptionService subService,
  ) {
    if (input.isEmpty) return '请粘贴订阅或节点链接';
    if (subService.isSingleNodeLink(input)) return null;

    try {
      SubscriptionUrlPolicy.parse(input);
    } on FormatException {
      return '请输入有效的节点链接或 HTTP/HTTPS 订阅链接';
    }
    return null;
  }

  Future<void> _showInitialSubscriptionDialog() async {
    if (_initialSubscriptionDialogInFlight) return;
    _initialSubscriptionDialogInFlight = true;

    final controller = TextEditingController();
    String? inputError;
    bool isSubmitting = false;

    try {
      await AppModalCoordinator.run<void>(() {
        if (!mounted || _disposed) return Future.value();
        return showSsrvpnGlassDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            final isDark =
                Theme.of(dialogContext).brightness == Brightness.dark;
            final titleColor = isDark
                ? SsrvpnTheme.of(context).textPrimary
                : SsrvpnTheme.of(context).textPrimary;
            final subtitleColor = isDark
                ? SsrvpnTheme.of(context).textSecondary
                : SsrvpnTheme.of(context).textSecondary;

            return StatefulBuilder(
              builder: (builderContext, setDialogState) {
                final mediaQuery = MediaQuery.of(builderContext);
                final maxDialogHeight = math.max(
                  160.0,
                  mediaQuery.size.height -
                      mediaQuery.padding.vertical -
                      mediaQuery.viewInsets.vertical -
                      48,
                );

                Future<void> submit() async {
                  final input = controller.text.trim();
                  final subService = builderContext.read<SubscriptionService>();
                  final settingsService =
                      builderContext.read<SettingsService>();
                  final navigator = Navigator.of(dialogContext);
                  final messenger = ScaffoldMessenger.of(builderContext);
                  final validationError = _validateSubscriptionInput(
                    input,
                    subService,
                  );
                  if (validationError != null) {
                    setDialogState(() => inputError = validationError);
                    return;
                  }

                  setDialogState(() {
                    inputError = null;
                    isSubmitting = true;
                  });

                  try {
                    final result =
                        await SubscriptionScreenController.fromService(
                                subService)
                            .addSubscription(input, retryExisting: true);
                    final nodes = HomeNodeController.runnableNodesFrom(
                      subService.allNodes,
                    );
                    if (!result.isSuccess || nodes.isEmpty) {
                      throw Exception(result.displayError.isNotEmpty
                          ? result.displayError
                          : '未获取到可用节点，请检查链接后重试');
                    }

                    if (!mounted || _disposed) return;
                    setState(() {
                      _nodes = nodes;
                      _lastRevision = subService.revision;
                      _selectedNode = HomeNodeController.resolveDefaultNodeFrom(
                        nodes,
                        settingsService.settings.lastSelectedNodeName,
                      );
                    });

                    if (navigator.canPop()) navigator.pop();
                    messenger.showSnackBar(
                      ssrvpnSnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text('节点已更新，获取到 ${nodes.length} 个节点'),
                        backgroundColor: SsrvpnTheme.of(context).success,
                      ),
                    );
                  } catch (e) {
                    if (!mounted || _disposed) return;
                    setDialogState(() {
                      inputError = safeSubscriptionFailureMessage(e);
                      isSubmitting = false;
                    });
                  }
                }

                return SsrvpnLiquidDialog(
                  backgroundColor: isDark ? Color(0xFF1A1D26) : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 420,
                      maxHeight: maxDialogHeight,
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
                      child: SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
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
                                    color: SsrvpnTheme.of(context)
                                        .primary
                                        .withValues(
                                          alpha: 22 / 255,
                                        ),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.rss_feed_rounded,
                                    color: SsrvpnTheme.of(context).primary,
                                    size: 22,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    '添加订阅',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      color: titleColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 18),
                            Text(
                              '请粘贴订阅或节点链接',
                              style:
                                  TextStyle(fontSize: 13, color: subtitleColor),
                            ),
                            SizedBox(height: 12),
                            TextField(
                              controller: controller,
                              minLines: 1,
                              maxLines: 4,
                              enabled: !isSubmitting,
                              decoration: InputDecoration(
                                hintText: '粘贴订阅或节点链接',
                                prefixIcon: Icon(Icons.link_rounded),
                                errorText: inputError,
                                filled: true,
                                fillColor: isDark
                                    ? Colors.white.withValues(alpha: 6 / 255)
                                    : Colors.black.withValues(alpha: 4 / 255),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: isDark
                                        ? SsrvpnTheme.of(context).border
                                        : SsrvpnTheme.of(context).border,
                                  ),
                                ),
                              ),
                              keyboardType: TextInputType.url,
                              onSubmitted: (_) {
                                if (!isSubmitting) submit();
                              },
                            ),
                            SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    onPressed: isSubmitting
                                        ? null
                                        : () => dismissSsrvpnDialog<void>(
                                            dialogContext),
                                    child: Text('取消'),
                                  ),
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: isSubmitting ? null : submit,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          SsrvpnTheme.of(context).primary,
                                      foregroundColor:
                                          SsrvpnTheme.of(context).onPrimary,
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    child: isSubmitting
                                        ? SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : Text('确定'),
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
              },
            );
          },
        );
      });
    } catch (error) {
      AppLogger.warning('SubscriptionDialog', '打开初始订阅窗口失败: $error');
      if (mounted && !_disposed) {
        _showHomeSnackBar(
          SnackBar(content: Text('无法打开订阅窗口，请稍后重试')),
        );
      }
    } finally {
      _initialSubscriptionDialogInFlight = false;
      controller.dispose();
    }
  }
}

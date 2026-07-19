part of desktop_home_screen;

extension _DesktopHomeInitialSubscriptionActions on _HomeScreenState {
  Future<void> _showInitialSubscriptionDialog() async {
    if (_initialSubscriptionDialogInFlight) return;
    _initialSubscriptionDialogInFlight = true;

    final controller = TextEditingController();
    String? inputError;
    bool isSubmitting = false;

    try {
      await AppModalCoordinator.run<void>(() {
        if (!mounted || _disposed) return Future.value();
        return showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            final isDark =
                Theme.of(dialogContext).brightness == Brightness.dark;
            final titleColor =
                isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
            final subtitleColor =
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

            return StatefulBuilder(
              builder: (builderContext, setDialogState) {
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
                    final exists = subService.subscriptions.any(
                      (sub) => sub.url == input,
                    );
                    if (!exists) {
                      await subService.addSubscription(
                        subService.defaultSubscriptionName(input),
                        input,
                      );
                    }

                    final yaml = await subService.refreshAllSubscriptions();
                    final nodes = HomeNodeController.runnableNodesFrom(
                      subService.allNodes,
                    );
                    if (yaml == null || yaml.trim().isEmpty || nodes.isEmpty) {
                      throw Exception('未获取到可用节点');
                    }

                    if (!mounted || _disposed) return;
                    setState(() {
                      _nodes = nodes;
                      _lastRevision = subService.revision;
                      _selectedNode = _resolveDefaultNode(
                        nodes,
                        settingsService.settings.lastSelectedNodeName,
                      );
                    });
                    unawaited(_autoTestAllNodes());

                    if (navigator.canPop()) navigator.pop();
                    messenger.showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text('节点已更新，获取到 ${nodes.length} 个节点'),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  } catch (e) {
                    if (!mounted || _disposed) return;
                    final msg = e.toString().replaceFirst('Exception: ', '');
                    setDialogState(() {
                      inputError = '更新失败: $msg';
                      isSubmitting = false;
                    });
                  }
                }

                return Dialog(
                  backgroundColor:
                      isDark ? const Color(0xFF1A1D26) : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
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
                                  color: AppTheme.primary.withValues(
                                    alpha: 22 / 255,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.rss_feed_rounded,
                                  color: AppTheme.primary,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
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
                          const SizedBox(height: 18),
                          Text(
                            '请粘贴你的SSR代码或订阅链接',
                            style:
                                TextStyle(fontSize: 13, color: subtitleColor),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: controller,
                            minLines: 1,
                            maxLines: 4,
                            enabled: !isSubmitting,
                            decoration: InputDecoration(
                              hintText: 'ssr:// 或 https://...',
                              prefixIcon: const Icon(Icons.link_rounded),
                              errorText: inputError,
                              filled: true,
                              fillColor: isDark
                                  ? Colors.white.withValues(alpha: 6 / 255)
                                  : Colors.black.withValues(alpha: 4 / 255),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: isDark
                                      ? AppTheme.border
                                      : AppTheme.lightBorder,
                                ),
                              ),
                            ),
                            keyboardType: TextInputType.url,
                            onSubmitted: (_) {
                              if (!isSubmitting) submit();
                            },
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: TextButton(
                                  onPressed: isSubmitting
                                      ? null
                                      : () => Navigator.of(dialogContext).pop(),
                                  child: const Text('取消'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: isSubmitting ? null : submit,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primary,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  child: isSubmitting
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text('确定'),
                                ),
                              ),
                            ],
                          ),
                        ],
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
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('无法打开订阅窗口，请稍后重试')),
        );
      }
    } finally {
      _initialSubscriptionDialogInFlight = false;
      controller.dispose();
    }
  }
}

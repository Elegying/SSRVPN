// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/utils/private_node_latency_policy.dart';
import '../models/app_settings.dart';
import '../services/clash_service.dart';
import '../services/ip_geo_service.dart';
import '../services/subscription_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_button.dart';
import '../widgets/glass_container.dart';
import '../widgets/liquid_glass.dart';
import 'node_edit_screen.dart';

/// 主屏幕 — Windows 桌面优化
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  List<ProxyNode> _nodes = [];
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isBatchTesting = false;
  String? _errorMessage;
  String? _testingNodeName;
  ProxyNode? _selectedNode;

  final Map<String, int> _latencies = {};
  Timer? _latencyBatchTimer;
  final Map<String, int> _pendingLatencies = {};
  int _lastRevision = -1;
  bool _disposed = false;
  bool _hasShownInitialSubscriptionDialog = false;
  ClashService? _clashService;
  Timer? _updateCheckTimer;
  late AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInitialData());
  }

  void _onSubscriptionChanged(SubscriptionService subService) {
    if (subService.revision == _lastRevision) return;
    final isFirstSync = _lastRevision == -1;
    _lastRevision = subService.revision;
    _nodes = List.from(subService.allNodes);
    if (!isFirstSync && _isConnected && _nodes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reloadConfig());
    }
  }

  Future<void> _reloadConfig() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final rawYaml = subService.rawYaml;
    if (rawYaml == null || rawYaml.isEmpty) return;

    setState(() => _isConnecting = true);
    try {
      final nodes = List<ProxyNode>.from(subService.allNodes);
      final preferredNode = _resolveDefaultNode(
        nodes,
        settingsService.settings.lastSelectedNodeName,
      );
      await clashService.stop();
      final runtimeSettings = await clashService.prepareForStart(
        settingsService.settings,
      );
      final config = clashService.generateClashConfig(
        rawYaml,
        runtimeSettings,
        preferredNodeName: preferredNode?.name,
      );
      await clashService.writeConfig(config);
      final success = await clashService.start();
      if (success && preferredNode != null) {
        final switched =
            await clashService.switchSelectedProxy(preferredNode.name);
        if (switched) await _rememberSelectedNode(preferredNode);
      }
      final connectivityWarning =
          success ? await clashService.verifyUserConnectivity() : null;
      if (mounted && !_disposed) {
        setState(() {
          _isConnected = success;
          _isConnecting = false;
          _errorMessage = connectivityWarning;
          _nodes = nodes;
          _selectedNode = success ? preferredNode : null;
        });
      }
    } catch (e) {
      if (mounted && !_disposed) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
      }
    }
  }

  void _scheduleLatencyFlush() {
    _latencyBatchTimer?.cancel();
    _latencyBatchTimer =
        Timer(const Duration(milliseconds: 100), _flushPendingLatencies);
  }

  void _flushPendingLatencies() {
    if (_pendingLatencies.isEmpty || !mounted || _disposed) return;
    final batch = Map<String, int>.from(_pendingLatencies);
    _pendingLatencies.clear();
    setState(() {
      _latencies.addAll(batch);
      for (final node in _nodes) {
        final latency = batch[node.name];
        if (latency != null) {
          node.latency = latency;
          node.lastLatencyTest = DateTime.now();
        }
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _latencyBatchTimer?.cancel();
    _updateCheckTimer?.cancel();
    _clashService?.removeStatusListener(_handleClashStatusChanged);
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final subService = context.read<SubscriptionService>();
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    _clashService = clashService;
    if (subService.allNodes.isNotEmpty) {
      final nodes = List<ProxyNode>.from(subService.allNodes);
      setState(() {
        _nodes = nodes;
        _lastRevision = subService.revision;
        if (clashService.isRunning) {
          _selectedNode = _resolveDefaultNode(
            nodes,
            settingsService.settings.lastSelectedNodeName,
          );
        }
      });
    }
    if (clashService.isRunning) {
      setState(() => _isConnected = true);
      _glowController.repeat();
    }

    clashService.addStatusListener(_handleClashStatusChanged);

    if (subService.allNodes.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_disposed) _showInitialSubscriptionDialog();
      });
    }
  }

  void _handleClashStatusChanged() {
    final clashService = _clashService;
    if (clashService == null || !mounted || _disposed) return;
    final running = clashService.isRunning;
    if (_isConnected == running) return;
    setState(() {
      _isConnected = running;
      if (!running) {
        _latencies.clear();
        _selectedNode = null;
        _glowController.stop();
      } else {
        _glowController.repeat();
      }
    });
  }

  Future<void> _showInitialSubscriptionDialog() async {
    if (_hasShownInitialSubscriptionDialog) return;
    _hasShownInitialSubscriptionDialog = true;

    final controller = TextEditingController();
    String? inputError;
    bool isSubmitting = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        final titleColor =
            isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
        final subtitleColor =
            isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

        return StatefulBuilder(
          builder: (builderContext, setDialogState) {
            Future<void> submit() async {
              final input = controller.text.trim();
              final subService = builderContext.read<SubscriptionService>();
              final settingsService = builderContext.read<SettingsService>();
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
                final exists =
                    subService.subscriptions.any((sub) => sub.url == input);
                if (!exists) {
                  await subService.addSubscription(
                    subService.isSsrLink(input) ? 'SSR节点' : 'SSRVPN.VIP',
                    input,
                  );
                }

                final yaml = await subService.refreshAllSubscriptions();
                if (yaml == null ||
                    yaml.trim().isEmpty ||
                    subService.allNodes.isEmpty) {
                  throw Exception('未获取到可用节点');
                }

                if (!mounted || _disposed) return;
                final nodes = List<ProxyNode>.from(subService.allNodes);
                setState(() {
                  _nodes = nodes;
                  _lastRevision = subService.revision;
                  _selectedNode = _resolveDefaultNode(
                    nodes,
                    settingsService.settings.lastSelectedNodeName,
                  );
                });

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
              backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
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
                              color:
                                  AppTheme.primary.withValues(alpha: 22 / 255),
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
                        style: TextStyle(fontSize: 13, color: subtitleColor),
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
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
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

    controller.dispose();
  }

  String? _validateSubscriptionInput(
    String input,
    SubscriptionService subService,
  ) {
    if (input.isEmpty) return '请粘贴你的SSR代码或订阅链接';
    if (subService.isSsrLink(input)) return null;

    final uri = Uri.tryParse(input);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '请输入有效的 SSR 代码或 HTTP/HTTPS 订阅链接';
    }
    return null;
  }

  Future<void> _applyNetworkSetting(
    Future<void> Function(SettingsService settings) update,
  ) async {
    if (_isConnecting) return;
    final clashService = context.read<ClashService>();
    final settingsService = context.read<SettingsService>();
    final wasConnected = clashService.isRunning || _isConnected;

    if (wasConnected) {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      await clashService.stop();
    }

    await update(settingsService);
    clashService.updateSettings(settingsService.settings);

    if (!mounted || _disposed) return;

    if (wasConnected) {
      await _reloadConfig();
    } else {
      setState(() {
        _isConnecting = false;
      });
    }
  }

  Future<void> _showForceProxySitesDialog() async {
    final settings = context.read<SettingsService>().settings;
    final savedSites = AppSettings.normalizeForceProxySites(
      settings.forceProxySites,
    );
    final controllers = List.generate(
      AppSettings.forceProxySiteLimit,
      (index) => TextEditingController(text: savedSites[index]),
    );
    String? errorText;

    final sites = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        final titleColor =
            isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
        final subtitleColor =
            isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

        return StatefulBuilder(
          builder: (builderContext, setDialogState) {
            void submit() {
              final values = controllers
                  .map((controller) => controller.text.trim())
                  .toList();
              for (var i = 0; i < values.length; i++) {
                final message = _validateForceProxySite(values[i]);
                if (message != null) {
                  setDialogState(() => errorText = '第 ${i + 1} 个输入框：$message');
                  return;
                }
              }
              Navigator.of(dialogContext).pop(values);
            }

            return Dialog(
              backgroundColor: isDark ? const Color(0xFF1A1D26) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(dialogContext).viewInsets.bottom,
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
                        for (var i = 0;
                            i < AppSettings.forceProxySiteLimit;
                            i++) ...[
                          TextField(
                            controller: controllers[i],
                            maxLines: 1,
                            keyboardType: TextInputType.url,
                            textInputAction:
                                i == AppSettings.forceProxySiteLimit - 1
                                    ? TextInputAction.done
                                    : TextInputAction.next,
                            inputFormatters: [
                              FilteringTextInputFormatter.deny(
                                RegExp(r'[\r\n]'),
                              ),
                            ],
                            decoration: GlassInputDecoration(
                              isDark: isDark,
                              labelText: '网址 ${i + 1}',
                              hintText: 'https://example.com',
                              prefixIcon: const Icon(Icons.language, size: 18),
                            ),
                            onSubmitted: (_) {
                              if (i == AppSettings.forceProxySiteLimit - 1) {
                                submit();
                              }
                            },
                          ),
                          if (i != AppSettings.forceProxySiteLimit - 1)
                            const SizedBox(height: 10),
                        ],
                        if (errorText != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            errorText!,
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
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(),
                                child: const Text('取消'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: submit,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primary,
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
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
          },
        );
      },
    );

    for (final controller in controllers) {
      controller.dispose();
    }
    if (sites == null || !mounted || _disposed) return;
    await _applyForceProxySites(sites);
  }

  String? _validateForceProxySite(String value) {
    if (value.trim().isEmpty) return null;
    if (RegExp(r'[\s,，;；]').hasMatch(value.trim())) {
      return '一个输入框只能填写一个网址';
    }
    if (AppSettings.extractForceProxyHost(value) == null) {
      return '请输入有效的网址或域名';
    }
    return null;
  }

  Future<void> _applyForceProxySites(List<String> sites) async {
    final settingsService = context.read<SettingsService>();
    final clashService = context.read<ClashService>();
    await settingsService.updateForceProxySites(sites);
    clashService.updateSettings(settingsService.settings);

    final shouldReload = _isConnected && !_isConnecting;
    var reloadSucceeded = false;
    if (shouldReload) {
      await _reloadConfig();
      reloadSucceeded = mounted &&
          !_disposed &&
          _isConnected &&
          context.read<ClashService>().isRunning;
    }
    if (!mounted || _disposed) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          shouldReload
              ? reloadSucceeded
                  ? '强制代理网站已实时生效'
                  : '强制代理网站已保存，当前连接重载失败，请重新连接'
              : '强制代理网站已保存',
        ),
        backgroundColor:
            shouldReload && !reloadSucceeded ? AppTheme.warning : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _handleConnectToggle() async {
    if (_isConnecting) return;
    final clashService = context.read<ClashService>();
    final subService = context.read<SubscriptionService>();
    final settingsService = context.read<SettingsService>();

    if (_isConnected) {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      await clashService.stop();
      if (!mounted) return;
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _latencies.clear();
        _glowController.stop();
      });
    } else {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
      final rawYaml = subService.rawYaml;
      if (rawYaml == null || rawYaml.isEmpty) {
        setState(() {
          _errorMessage = '请先添加并刷新订阅';
          _isConnecting = false;
        });
        return;
      }
      try {
        final nodes = List<ProxyNode>.from(subService.allNodes);
        final autoSelect = _resolveDefaultNode(
          nodes,
          settingsService.settings.lastSelectedNodeName,
        );
        final runtimeSettings = await clashService.prepareForStart(
          settingsService.settings,
        );
        final config = clashService.generateClashConfig(
          rawYaml,
          runtimeSettings,
          preferredNodeName: autoSelect?.name,
        );
        await clashService.writeConfig(config);
        final success = await clashService.start();
        if (!mounted) return;
        if (success) {
          if (autoSelect != null) {
            final switched =
                await clashService.switchSelectedProxy(autoSelect.name);
            if (switched) await _rememberSelectedNode(autoSelect);
          }
          final connectivityWarning =
              await clashService.verifyUserConnectivity();
          setState(() {
            _isConnected = true;
            _isConnecting = false;
            _errorMessage = connectivityWarning;
            _nodes = nodes;
            _selectedNode = autoSelect;
          });
          _glowController.repeat();
          _autoTestAllNodes();
          _checkUpdateDelayed();
        } else {
          setState(() {
            _errorMessage = '连接失败: ${clashService.lastStartError ?? "无法启动核心"}';
            _isConnecting = false;
          });
        }
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _errorMessage = '连接失败: $msg';
          _isConnecting = false;
        });
      }
    }
  }

  void _checkUpdateDelayed() {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer(const Duration(seconds: 10), () async {
      if (!mounted || !_isConnected) return;
      try {
        const currentVersion = UpdateService.appVersion;
        final result = await UpdateService.checkForUpdate(currentVersion);
        if (result != null && mounted && _isConnected) {
          final (latestVersion, downloadUrl, changelog) = result;
          UpdateService.showUpdateDialog(
            context,
            latestVersion: latestVersion,
            currentVersion: currentVersion,
            downloadUrl: downloadUrl,
            changelog: changelog,
          );
        }
      } catch (e) {
        debugPrint('[更新] 检查更新异常: $e');
      }
    });
  }

  Future<void> _handleTestLatency(
      String nodeName, String server, int port) async {
    if (!_isConnected || _testingNodeName == nodeName) return;
    setState(() => _testingNodeName = nodeName);
    final clashService = context.read<ClashService>();
    final settings = context.read<SettingsService>().settings;
    final measuredLatency = await clashService.testLatency(
      server,
      port,
      timeoutMs: settings.latencyTestTimeout,
    );
    final latency = PrivateNodeLatencyPolicy.displayLatencyForNode(
      nodeName,
      measuredLatency,
      random: math.Random(),
    );
    if (mounted && !_disposed) {
      setState(() {
        _latencies[nodeName] = latency;
        _testingNodeName = null;
        for (final node in _nodes) {
          if (node.name == nodeName) {
            node.latency = latency;
            node.lastLatencyTest = DateTime.now();
          }
        }
      });
    }
  }

  Future<void> _handleSelectNode(ProxyNode node) async {
    if (!_isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('请先连接VPN'), duration: Duration(seconds: 1)),
        );
      }
      return;
    }
    final ok =
        await context.read<ClashService>().switchSelectedProxy(node.name);
    if (ok) {
      await _rememberSelectedNode(node);
      if (mounted) setState(() => _selectedNode = node);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(ok ? '已切换: ${node.name}' : '切换失败: ${node.name}'),
            duration: const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _showNodeContextMenu(
    ProxyNode node,
    TapDownDetails details,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18),
              SizedBox(width: 10),
              Text('编辑'),
            ],
          ),
        ),
      ],
    );
    if (selected != 'edit' || !mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NodeEditScreen(node: node),
      ),
    );
  }

  ProxyNode? _resolveDefaultNode(
    List<ProxyNode> nodes,
    String? rememberedNodeName,
  ) {
    if (nodes.isEmpty) return null;
    if (rememberedNodeName != null && rememberedNodeName.isNotEmpty) {
      for (final node in nodes) {
        if (node.name == rememberedNodeName) return node;
      }
    }
    return nodes.first;
  }

  Future<void> _rememberSelectedNode(ProxyNode node) async {
    final settingsService = context.read<SettingsService>();
    if (settingsService.settings.lastSelectedNodeName == node.name) return;
    await settingsService.updateLastSelectedNodeName(node.name);
  }

  Future<void> _autoTestAllNodes() async {
    if (!_isConnected || _nodes.isEmpty) return;
    final clashService = context.read<ClashService>();
    final timeout = context.read<SettingsService>().settings.latencyTestTimeout;
    setState(() => _isBatchTesting = true);
    _pendingLatencies.clear();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _pendingLatencies[name] = latency;
      _scheduleLatencyFlush();
    }, timeoutMs: timeout);
    _latencyBatchTimer?.cancel();
    _flushPendingLatencies();
    if (mounted && !_disposed) {
      setState(() => _isBatchTesting = false);
    }
  }

  Future<void> _handleTestAllLatency() async {
    if (!_isConnected) return;
    final clashService = context.read<ClashService>();
    final timeout = context.read<SettingsService>().settings.latencyTestTimeout;
    setState(() => _isBatchTesting = true);
    _pendingLatencies.clear();
    await clashService.testAllLatencies(_nodes, (name, latency) {
      _pendingLatencies[name] = latency;
      _scheduleLatencyFlush();
    }, timeoutMs: timeout);
    _latencyBatchTimer?.cancel();
    _flushPendingLatencies();
    if (mounted && !_disposed) {
      setState(() => _isBatchTesting = false);
    }
  }

  void _showTutorial(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: GlassContainer(
          borderRadius: 16,
          enablePress: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (MediaQuery.of(ctx).size.width * 0.88)
                  .clamp(
                    280.0,
                    420.0,
                  )
                  .toDouble(),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                              colors: [AppTheme.primary, AppTheme.accentColor]),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.menu_book_rounded,
                            color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Text('使用教程',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? AppTheme.textPrimary
                                  : AppTheme.lightTextPrimary)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const _TutorialStep(step: '1', text: '点击底部「订阅」标签，进入订阅管理页面'),
                  const SizedBox(height: 12),
                  const _TutorialStep(step: '2', text: '在输入框中粘贴订阅链接，点击「添加」'),
                  const SizedBox(height: 12),
                  const _TutorialStep(
                      step: '3', text: '添加成功后点击「全部刷新」，等待节点加载完成'),
                  const SizedBox(height: 12),
                  const _TutorialStep(step: '4', text: '返回主页，点击连接按钮即可使用'),
                  const SizedBox(height: 12),
                  const _TutorialStep(
                      step: '5', text: '系统代理模式无需管理员权限，TUN 模式需以管理员身份运行'),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        backgroundColor: AppTheme.primary
                            .withValues(alpha: (isDark ? 25 : 15) / 255),
                      ),
                      child: const Text('知道了',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showLogs(BuildContext context) {
    final clashService = context.read<ClashService>();
    final logs = clashService.recentLogs;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0E1018),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.88),
          child: Container(
            width: 600,
            height: 500,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.bug_report,
                        size: 18, color: AppTheme.warning),
                    const SizedBox(width: 8),
                    const Text('运行日志',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.copy,
                          size: 18, color: AppTheme.textSecondary),
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: clashService.recentLogs));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  content: Text('日志已复制')));
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: AppTheme.textSecondary),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(color: AppTheme.border),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      logs.isEmpty ? '暂无日志' : logs,
                      style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'Consolas',
                          color: AppTheme.textSecondary,
                          height: 1.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>().settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    final subService = context.watch<SubscriptionService>();
    _onSubscriptionChanged(subService);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _buildLiquidDashboard(isDark, textColor, subColor, settings),
    );
  }

  Widget _buildLiquidDashboard(
    bool isDark,
    Color textColor,
    Color subColor,
    AppSettings settings,
  ) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 880;
          final padding = wide
              ? const EdgeInsets.fromLTRB(24, 18, 24, 24)
              : const EdgeInsets.fromLTRB(0, 0, 0, 0);

          if (!wide) {
            return Column(
              children: [
                _buildTopBar(isDark, textColor),
                _buildStatusBar(isDark, textColor, subColor, settings),
                Expanded(child: _buildNodeList(textColor, subColor, isDark)),
              ],
            );
          }

          return Padding(
            padding: padding,
            child: Column(
              children: [
                _buildTopBar(isDark, textColor),
                const SizedBox(height: 10),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 420,
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: _buildStatusBar(
                            isDark,
                            textColor,
                            subColor,
                            settings,
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: LiquidGlassContainer(
                          blur: 30,
                          opacity: isDark ? 0.045 : 0.5,
                          borderRadius:
                              const BorderRadius.all(Radius.circular(26)),
                          padding: EdgeInsets.zero,
                          borderOpacity: isDark ? 0.16 : 0.72,
                          child: _buildNodeList(textColor, subColor, isDark),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopBar(bool isDark, Color textColor) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 430;
        return Padding(
          padding:
              EdgeInsets.fromLTRB(compact ? 20 : 28, 14, compact ? 20 : 28, 6),
          child: Row(
            children: [
              // 品牌标识
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.primary, AppTheme.accentColor],
                  ),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 40 / 255),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.shield_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Text('SSRVPN',
                  style: TextStyle(
                      fontSize: compact ? 17 : 19,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                      letterSpacing: 0)),
              if (!compact) ...[
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 15 / 255),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 30 / 255),
                    ),
                  ),
                  child: const Text('Windows',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: AppTheme.primary)),
                ),
              ],
              const Spacer(),
              // 右侧操作
              if (_isConnected && !compact)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 15 / 255),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.success.withValues(alpha: 30 / 255),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          size: 13, color: AppTheme.success),
                      SizedBox(width: 4),
                      Text('已连接',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.success,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              Tooltip(
                message: '使用教程',
                child: GestureDetector(
                  onTap: () => _showTutorial(context),
                  child: Container(
                    height: 38,
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 11 : 14,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppTheme.primary, AppTheme.accentColor],
                      ),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.26),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.24),
                          blurRadius: 18,
                          spreadRadius: -8,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.menu_book_rounded,
                            size: 16, color: Colors.white),
                        if (!compact) ...[
                          const SizedBox(width: 7),
                          Text('教程',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatusBar(
      bool isDark, Color textColor, Color subColor, AppSettings settings) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 430;
        return Padding(
          padding:
              EdgeInsets.fromLTRB(compact ? 20 : 28, 10, compact ? 20 : 28, 10),
          child: AnimatedBuilder(
            animation: _glowController,
            builder: (context, child) {
              final glowIntensity = _isConnected
                  ? 0.2 + 0.12 * math.sin(_glowController.value * 2 * math.pi)
                  : 0.0;
              final glowColor = AppTheme.success.withAlpha(
                (glowIntensity * 255).toInt(),
              );
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: _isConnected
                      ? [
                          BoxShadow(
                            color: glowColor,
                            blurRadius: 28,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: LiquidGlassContainer(
                  blur: 34,
                  opacity: isDark ? 0.055 : 0.58,
                  borderRadius: const BorderRadius.all(Radius.circular(24)),
                  padding:
                      const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
                  borderOpacity: isDark ? 0.17 : 0.72,
                  shadowOpacity: isDark ? 0.42 : 0.1,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          ConnectionButton(
                            isConnected: _isConnected,
                            isConnecting: _isConnecting,
                            onTap: _handleConnectToggle,
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _ForceProxyButton(
                                  onTap: _showForceProxySitesDialog,
                                  enabled: !_isConnecting,
                                ),
                                const SizedBox(height: 12),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 300),
                                  child: Text(
                                    _isConnecting
                                        ? '正在连接...'
                                        : _isConnected
                                            ? '已连接'
                                            : '未连接',
                                    key: ValueKey(_isConnecting
                                        ? 'c'
                                        : _isConnected
                                            ? 'y'
                                            : 'n'),
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: _isConnected
                                          ? AppTheme.success
                                          : textColor,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                if (_isConnected)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppTheme.success
                                          .withValues(alpha: 15 / 255),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '${settings.proxyMode.chineseName} · 端口 ${settings.proxyPort}${settings.enableTun ? " · TUN" : " · 代理"}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: subColor,
                                          fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                if (_errorMessage != null) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: AppTheme.error
                                          .withValues(alpha: 15 / 255),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: AppTheme.error
                                              .withValues(alpha: 40 / 255)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.error_outline,
                                                size: 14,
                                                color: AppTheme.error),
                                            const SizedBox(width: 6),
                                            Expanded(
                                                child: Text(_errorMessage!,
                                                    style: const TextStyle(
                                                        color: AppTheme.error,
                                                        fontSize: 12))),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        GestureDetector(
                                          onTap: () => _showLogs(context),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.bug_report,
                                                  size: 12,
                                                  color: AppTheme.warning),
                                              const SizedBox(width: 4),
                                              Text('查看日志',
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: AppTheme.warning
                                                          .withValues(
                                                              alpha: 200 / 255),
                                                      decoration: TextDecoration
                                                          .underline)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildConnectionOptions(
                          isDark, textColor, subColor, settings),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildConnectionOptions(
    bool isDark,
    Color textColor,
    Color subColor,
    AppSettings settings,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 4 / 255)
            : Colors.black.withValues(alpha: 4 / 255),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppTheme.border : AppTheme.lightBorder,
          width: 0.5,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final modeControl = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '代理模式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ProxyMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<ProxyMode>(
                      value: ProxyMode.rule,
                      icon: Icon(Icons.route_rounded, size: 16),
                      label: Text('规则'),
                    ),
                    ButtonSegment<ProxyMode>(
                      value: ProxyMode.global,
                      icon: Icon(Icons.public_rounded, size: 16),
                      label: Text('全局'),
                    ),
                  ],
                  selected: {settings.proxyMode},
                  onSelectionChanged: _isConnecting
                      ? null
                      : (selection) {
                          _applyNetworkSetting(
                            (service) =>
                                service.updateProxyMode(selection.first),
                          );
                        },
                ),
              ),
            ],
          );

          Widget tunChoice({
            required bool selected,
            required bool enableTun,
            required IconData icon,
            required String label,
          }) {
            final disabled = _isConnecting || selected;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: disabled
                  ? null
                  : () {
                      _applyNetworkSetting(
                        (service) => service.updateEnableTun(enableTun),
                      );
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.primary
                          .withValues(alpha: (isDark ? 28 : 18) / 255)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? AppTheme.primary.withValues(alpha: 120 / 255)
                        : (isDark ? AppTheme.border : AppTheme.lightBorder),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: selected ? AppTheme.primary : subColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.25,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? AppTheme.primary : textColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: selected ? AppTheme.primary : subColor,
                    ),
                  ],
                ),
              ),
            );
          }

          final tunControl = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '代理方式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              tunChoice(
                selected: !settings.enableTun,
                enableTun: false,
                icon: Icons.language_rounded,
                label: '系统代理（默认）',
              ),
              tunChoice(
                selected: settings.enableTun,
                enableTun: true,
                icon: Icons.wifi_tethering_rounded,
                label: 'TUN 模式（需管理员权限）',
              ),
            ],
          );

          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                modeControl,
                const SizedBox(height: 12),
                tunControl,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: modeControl),
              Container(
                width: 1,
                height: 52,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                color: isDark ? AppTheme.border : AppTheme.lightBorder,
              ),
              Expanded(child: tunControl),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNodeList(Color textColor, Color subColor, bool isDark) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 10, 28, 8),
          child: Row(
            children: [
              Container(
                  width: 3,
                  height: 16,
                  decoration: BoxDecoration(
                      color: AppTheme.primary,
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 10),
              Text('全部节点',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: textColor)),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 15 / 255),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 25 / 255),
                    )),
                child: Text('${_nodes.length}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primary)),
              ),
              const Spacer(),
              if (_isBatchTesting)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.primary))
              else if (_isConnected)
                _SmallButton(
                    icon: Icons.speed,
                    label: '测速',
                    onTap: _handleTestAllLatency),
            ],
          ),
        ),
        Expanded(child: _buildNodeListView(textColor, subColor, isDark)),
      ],
    );
  }

  Widget _buildNodeListView(Color textColor, Color subColor, bool isDark) {
    if (_isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: AppTheme.primary)),
            const SizedBox(height: 16),
            Text('正在启动核心...', style: TextStyle(fontSize: 14, color: subColor)),
          ],
        ),
      );
    }

    if (_nodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 10 / 255),
                  shape: BoxShape.circle),
              child: Icon(Icons.dns_outlined,
                  size: 32,
                  color: AppTheme.primary.withValues(alpha: 100 / 255)),
            ),
            const SizedBox(height: 20),
            Text('暂无节点',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textColor)),
            const SizedBox(height: 8),
            Text('请先在订阅页面添加订阅链接',
                style: TextStyle(fontSize: 13, color: subColor)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      itemCount: _nodes.length,
      itemBuilder: (context, index) {
        final node = _nodes[index];
        final latency = _latencies[node.name] ?? node.latency;
        final isTesting = _testingNodeName == node.name;
        final isSelected = _selectedNode?.name == node.name;
        final isTimeout = latency != null && (latency <= 0 || latency >= 65535);

        return _NodeCard(
          node: node,
          latency: latency,
          isTesting: isTesting,
          isSelected: isSelected,
          isTimeout: isTimeout,
          isConnected: _isConnected,
          onTestLatency: () =>
              _handleTestLatency(node.name, node.server, node.port),
          onTap: () => _handleSelectNode(node),
          onSecondaryTapDown: (details) => _showNodeContextMenu(node, details),
          textColor: textColor,
          subColor: subColor,
          isDark: isDark,
        );
      },
    );
  }
}

class _ForceProxyButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool enabled;

  const _ForceProxyButton({
    required this.onTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 168),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: (isDark ? 24 : 16) / 255),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color:
                  AppTheme.primary.withValues(alpha: (isDark ? 70 : 55) / 255),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_link_rounded,
                size: 16,
                color: AppTheme.primary,
              ),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                  '添加强制代理网站',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SmallButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.card : AppTheme.lightBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isDark ? AppTheme.border : AppTheme.lightBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppTheme.primary),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.primary)),
          ],
        ),
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  final ProxyNode node;
  final int? latency;
  final bool isTesting;
  final bool isSelected;
  final bool isTimeout;
  final bool isConnected;
  final VoidCallback onTestLatency;
  final VoidCallback onTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final Color textColor;
  final Color subColor;
  final bool isDark;

  const _NodeCard({
    required this.node,
    required this.latency,
    required this.isTesting,
    required this.isSelected,
    required this.isTimeout,
    required this.isConnected,
    required this.onTestLatency,
    required this.onTap,
    required this.onSecondaryTapDown,
    required this.textColor,
    required this.subColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveTextColor =
        isTimeout ? textColor.withValues(alpha: 80 / 255) : textColor;
    final effectiveSubColor =
        isTimeout ? subColor.withValues(alpha: 60 / 255) : subColor;

    return _HoverableNodeCard(
      enabled: !isTimeout,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: GestureDetector(
          onTap: isTimeout ? null : onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isSelected
                  ? (isDark
                      ? AppTheme.success.withValues(alpha: 15 / 255)
                      : AppTheme.success.withValues(alpha: 10 / 255))
                  : null,
              border: Border.all(
                color: isSelected
                    ? AppTheme.success.withValues(alpha: 80 / 255)
                    : isDark
                        ? AppTheme.border
                        : AppTheme.lightBorder,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Opacity(
              opacity: isTimeout ? 0.45 : 1.0,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    _NodeFlagBadge(
                      node: node,
                      selected: isSelected,
                      timeout: isTimeout,
                      isDark: isDark,
                      isConnected: isConnected,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(node.name,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? AppTheme.success
                                      : effectiveTextColor),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 3),
                          Row(children: [
                            _TypeBadge(type: node.type, isTimeout: isTimeout),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text('${node.server}:${node.port}',
                                    style: TextStyle(
                                        fontSize: 11, color: effectiveSubColor),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis)),
                          ]),
                        ],
                      ),
                    ),
                    if (isTesting)
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.primary))
                    else if (isTimeout)
                      const _LatencyBadge(latency: 65535)
                    else if (latency != null && latency! > 0)
                      _LatencyBadge(latency: latency!)
                    else if (isConnected)
                      GestureDetector(
                        onTap: onTestLatency,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                              color:
                                  AppTheme.primary.withValues(alpha: 15 / 255),
                              borderRadius: BorderRadius.circular(6)),
                          child: Text('测速',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.primary
                                      .withValues(alpha: 200 / 255))),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverableNodeCard extends StatefulWidget {
  const _HoverableNodeCard({
    required this.child,
    required this.enabled,
  });

  final Widget child;
  final bool enabled;

  @override
  State<_HoverableNodeCard> createState() => _HoverableNodeCardState();
}

class _HoverableNodeCardState extends State<_HoverableNodeCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: widget.enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: widget.enabled ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedScale(
        scale: _hovered ? 1.006 : 1,
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: _hovered ? const Offset(0, -0.018) : Offset.zero,
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutCubic,
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                if (_hovered)
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.18),
                    blurRadius: 20,
                    spreadRadius: -14,
                    offset: const Offset(0, 12),
                  ),
              ],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _NodeFlagBadge extends StatefulWidget {
  const _NodeFlagBadge({
    required this.node,
    required this.selected,
    required this.timeout,
    required this.isDark,
    required this.isConnected,
  });

  final ProxyNode node;
  final bool selected;
  final bool timeout;
  final bool isDark;
  final bool isConnected;

  @override
  State<_NodeFlagBadge> createState() => _NodeFlagBadgeState();
}

class _NodeFlagBadgeState extends State<_NodeFlagBadge> {
  late Future<String> _countryFuture;

  @override
  void initState() {
    super.initState();
    _loadCountry();
  }

  @override
  void didUpdateWidget(covariant _NodeFlagBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.name != widget.node.name ||
        oldWidget.node.server != widget.node.server ||
        oldWidget.isConnected != widget.isConnected) {
      _loadCountry();
    }
  }

  void _loadCountry() {
    _countryFuture = IpGeoService.instance.countryCodeForNode(
      widget.node,
      context.read<ClashService>(),
      connected: widget.isConnected,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cached = IpGeoService.instance.cachedCountryForNode(widget.node);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        FutureBuilder<String>(
          future: _countryFuture,
          initialData: cached,
          builder: (context, snapshot) {
            final countryCode = _normalizeCountry(snapshot.data ?? 'UN');
            return AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color:
                    widget.isDark ? const Color(0xFF080E18) : AppTheme.lightBg,
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.selected
                      ? AppTheme.success.withValues(alpha: 0.9)
                      : AppTheme.borderLight.withValues(
                          alpha: widget.isDark ? 0.9 : 0.45,
                        ),
                ),
                boxShadow: [
                  if (widget.selected)
                    BoxShadow(
                      color: AppTheme.success.withValues(alpha: 0.25),
                      blurRadius: 14,
                      spreadRadius: -8,
                    ),
                ],
              ),
              child: ClipOval(
                child: CustomPaint(
                  painter: _CountryFlagPainter(countryCode),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          },
        ),
        if (widget.selected)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(
                color: AppTheme.success,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 10,
                color: Colors.white,
              ),
            ),
          ),
        if (widget.timeout)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

// ignore: unused_element
String _countryCodeForNode(ProxyNode node) {
  const extraKeys = [
    'country',
    'countryCode',
    'country-code',
    'region',
    'regionCode',
    'ipCountry',
  ];
  for (final key in extraKeys) {
    final value = node.extra[key]?.toString().trim().toUpperCase();
    if (value != null && value.length == 2) return _normalizeCountry(value);
  }

  final haystack = '${node.name} ${node.server}'.toUpperCase();
  final patterns = <String, List<String>>{
    'HK': ['HK', 'HKG', '香港', 'HONG KONG'],
    'SG': ['SG', 'SGP', '新加坡', 'SINGAPORE'],
    'TW': ['TW', 'TWN', '台湾', '台灣', 'TAIWAN'],
    'JP': ['JP', 'JPN', '日本', 'JAPAN', 'TOKYO', 'OSAKA'],
    'US': ['US', 'USA', '美国', '美國', 'UNITED STATES', 'LOS ANGELES'],
    'GB': ['GB', 'UK', '英国', '英國', 'UNITED KINGDOM', 'LONDON'],
    'KR': ['KR', 'KOR', '韩国', '韓國', 'KOREA', 'SEOUL'],
    'DE': ['DE', 'DEU', '德国', '德國', 'GERMANY'],
    'FR': ['FR', 'FRA', '法国', '法國', 'FRANCE'],
    'NL': ['NL', 'NLD', '荷兰', '荷蘭', 'NETHERLANDS'],
    'CA': ['CA', 'CAN', '加拿大', 'CANADA'],
    'AU': ['AU', 'AUS', '澳大利亚', '澳洲', 'AUSTRALIA'],
    'IN': ['IN', 'IND', '印度', 'INDIA'],
    'TH': ['TH', 'THA', '泰国', '泰國', 'THAILAND'],
    'VN': ['VN', 'VNM', '越南', 'VIETNAM'],
    'MY': ['MY', 'MYS', '马来', '馬來', 'MALAYSIA'],
    'PH': ['PH', 'PHL', '菲律宾', '菲律賓', 'PHILIPPINES'],
    'ID': ['ID', 'IDN', '印尼', '印度尼西亚', 'INDONESIA'],
    'RU': ['RU', 'RUS', '俄罗斯', '俄羅斯', 'RUSSIA'],
    'BR': ['BR', 'BRA', '巴西', 'BRAZIL'],
  };

  for (final entry in patterns.entries) {
    for (final token in entry.value) {
      if (RegExp('(^|[^A-Z])${RegExp.escape(token)}([^A-Z]|\$)')
          .hasMatch(haystack)) {
        return entry.key;
      }
    }
  }

  final tldMatch = RegExp(r'\.([a-z]{2})(?::\d+)?$', caseSensitive: false)
      .firstMatch(node.server);
  if (tldMatch != null) return _normalizeCountry(tldMatch.group(1) ?? 'UN');

  return 'UN';
}

String _normalizeCountry(String code) {
  final upper = code.toUpperCase();
  if (upper == 'UK') return 'GB';
  if (upper == 'EL') return 'GR';
  return upper;
}

class _CountryFlagPainter extends CustomPainter {
  const _CountryFlagPainter(this.countryCode);

  final String countryCode;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipPath(Path()..addOval(rect));
    switch (countryCode) {
      case 'US':
        _horizontalStripes(canvas, rect, const [
          Color(0xFFB22234),
          Colors.white,
          Color(0xFFB22234),
          Colors.white,
          Color(0xFFB22234),
          Colors.white,
          Color(0xFFB22234),
        ]);
        _fill(
            canvas,
            Rect.fromLTWH(0, 0, size.width * 0.48, size.height * 0.48),
            const Color(0xFF3C3B6E));
        break;
      case 'JP':
        _fill(canvas, rect, Colors.white);
        canvas.drawCircle(rect.center, size.shortestSide * 0.22,
            Paint()..color = const Color(0xFFBC002D));
        break;
      case 'HK':
      case 'CN':
        _fill(canvas, rect, const Color(0xFFDE2910));
        _star(canvas, Offset(size.width * 0.34, size.height * 0.32),
            size.shortestSide * 0.12, const Color(0xFFFFDE00));
        break;
      case 'SG':
        _horizontalStripes(canvas, rect, const [
          Color(0xFFEF3340),
          Colors.white,
        ]);
        _crescent(canvas, Offset(size.width * 0.34, size.height * 0.28),
            size.shortestSide * 0.12);
        break;
      case 'TW':
        _fill(canvas, rect, const Color(0xFFFE0000));
        _fill(
            canvas,
            Rect.fromLTWH(0, 0, size.width * 0.52, size.height * 0.52),
            const Color(0xFF000095));
        _star(canvas, Offset(size.width * 0.26, size.height * 0.26),
            size.shortestSide * 0.11, Colors.white);
        break;
      case 'GB':
        _fill(canvas, rect, const Color(0xFF012169));
        _diagonal(canvas, rect, Colors.white, size.shortestSide * 0.18);
        _cross(canvas, rect, Colors.white, size.shortestSide * 0.2);
        _diagonal(
            canvas, rect, const Color(0xFFC8102E), size.shortestSide * 0.08);
        _cross(canvas, rect, const Color(0xFFC8102E), size.shortestSide * 0.1);
        break;
      case 'DE':
        _horizontalStripes(canvas, rect,
            const [Colors.black, Color(0xFFDD0000), Color(0xFFFFCE00)]);
        break;
      case 'FR':
        _verticalStripes(canvas, rect,
            const [Color(0xFF0055A4), Colors.white, Color(0xFFEF4135)]);
        break;
      case 'NL':
        _horizontalStripes(canvas, rect,
            const [Color(0xFFAE1C28), Colors.white, Color(0xFF21468B)]);
        break;
      case 'RU':
        _horizontalStripes(canvas, rect,
            const [Colors.white, Color(0xFF0039A6), Color(0xFFD52B1E)]);
        break;
      case 'KR':
        _fill(canvas, rect, Colors.white);
        canvas.drawCircle(rect.center, size.shortestSide * 0.2,
            Paint()..color = const Color(0xFFC60C30));
        canvas.drawArc(
          Rect.fromCircle(center: rect.center, radius: size.shortestSide * 0.2),
          0,
          math.pi,
          true,
          Paint()..color = const Color(0xFF003478),
        );
        break;
      case 'CA':
        _verticalStripes(canvas, rect,
            const [Color(0xFFD80621), Colors.white, Color(0xFFD80621)]);
        _star(canvas, rect.center, size.shortestSide * 0.1,
            const Color(0xFFD80621));
        break;
      case 'AU':
        _fill(canvas, rect, const Color(0xFF00008B));
        _star(canvas, Offset(size.width * 0.68, size.height * 0.6),
            size.shortestSide * 0.1, Colors.white);
        break;
      case 'IN':
        _horizontalStripes(canvas, rect,
            const [Color(0xFFFF9933), Colors.white, Color(0xFF138808)]);
        canvas.drawCircle(rect.center, size.shortestSide * 0.08,
            Paint()..color = const Color(0xFF000080));
        break;
      case 'TH':
        _horizontalStripes(canvas, rect, const [
          Color(0xFFA51931),
          Colors.white,
          Color(0xFF2D2A4A),
          Color(0xFF2D2A4A),
          Colors.white,
          Color(0xFFA51931),
        ]);
        break;
      case 'VN':
        _fill(canvas, rect, const Color(0xFFDA251D));
        _star(canvas, rect.center, size.shortestSide * 0.16,
            const Color(0xFFFFFF00));
        break;
      case 'MY':
        _horizontalStripes(canvas, rect, const [
          Color(0xFFCC0001),
          Colors.white,
          Color(0xFFCC0001),
          Colors.white
        ]);
        _fill(canvas, Rect.fromLTWH(0, 0, size.width * 0.5, size.height * 0.5),
            const Color(0xFF010066));
        break;
      case 'ID':
        _horizontalStripes(
            canvas, rect, const [Color(0xFFFF0000), Colors.white]);
        break;
      case 'BR':
        _fill(canvas, rect, const Color(0xFF009B3A));
        _diamond(canvas, rect, const Color(0xFFFFDF00));
        canvas.drawCircle(rect.center, size.shortestSide * 0.12,
            Paint()..color = const Color(0xFF002776));
        break;
      default:
        _fill(canvas, rect, const Color(0xFF111827));
        _drawCode(canvas, rect, countryCode == 'UN' ? '--' : countryCode);
        break;
    }
    canvas.restore();
  }

  void _fill(Canvas canvas, Rect rect, Color color) {
    canvas.drawRect(rect, Paint()..color = color);
  }

  void _horizontalStripes(Canvas canvas, Rect rect, List<Color> colors) {
    final stripeHeight = rect.height / colors.length;
    for (var i = 0; i < colors.length; i++) {
      _fill(
        canvas,
        Rect.fromLTWH(rect.left, rect.top + i * stripeHeight, rect.width,
            stripeHeight + 0.5),
        colors[i],
      );
    }
  }

  void _verticalStripes(Canvas canvas, Rect rect, List<Color> colors) {
    final stripeWidth = rect.width / colors.length;
    for (var i = 0; i < colors.length; i++) {
      _fill(
        canvas,
        Rect.fromLTWH(rect.left + i * stripeWidth, rect.top, stripeWidth + 0.5,
            rect.height),
        colors[i],
      );
    }
  }

  void _cross(Canvas canvas, Rect rect, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(Offset(rect.left, rect.center.dy),
        Offset(rect.right, rect.center.dy), paint);
    canvas.drawLine(Offset(rect.center.dx, rect.top),
        Offset(rect.center.dx, rect.bottom), paint);
  }

  void _diagonal(Canvas canvas, Rect rect, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
    canvas.drawLine(rect.topRight, rect.bottomLeft, paint);
  }

  void _diamond(Canvas canvas, Rect rect, Color color) {
    final path = Path()
      ..moveTo(rect.center.dx, rect.top + rect.height * 0.18)
      ..lineTo(rect.right - rect.width * 0.16, rect.center.dy)
      ..lineTo(rect.center.dx, rect.bottom - rect.height * 0.18)
      ..lineTo(rect.left + rect.width * 0.16, rect.center.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _star(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final r = i.isEven ? radius : radius * 0.42;
      final point = Offset(
          center.dx + math.cos(angle) * r, center.dy + math.sin(angle) * r);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _crescent(Canvas canvas, Offset center, double radius) {
    canvas.drawCircle(center, radius, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(center.dx + radius * 0.42, center.dy),
        radius * 0.86, Paint()..color = const Color(0xFFEF3340));
  }

  void _drawCode(Canvas canvas, Rect rect, String code) {
    final painter = TextPainter(
      text: TextSpan(
        text: code,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);
    painter.paint(
        canvas, rect.center - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CountryFlagPainter oldDelegate) {
    return oldDelegate.countryCode != countryCode;
  }
}

class _TypeBadge extends StatelessWidget {
  final String type;
  final bool isTimeout;
  const _TypeBadge({required this.type, this.isTimeout = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final display = type.toUpperCase().length > 4
        ? type.toUpperCase().substring(0, 4)
        : type.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: AppTheme.primary.withAlpha(isTimeout ? 8 : (isDark ? 20 : 15)),
          borderRadius: BorderRadius.circular(4)),
      child: Text(display,
          style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: AppTheme.primary
                  .withValues(alpha: (isTimeout ? 100 : 255) / 255),
              letterSpacing: 0.5)),
    );
  }
}

class _LatencyBadge extends StatelessWidget {
  final int latency;
  const _LatencyBadge({required this.latency});

  bool get isTimeout => latency <= 0 || latency >= 65535;

  @override
  Widget build(BuildContext context) {
    final color = isTimeout
        ? AppTheme.error
        : latency < 200
            ? AppTheme.success
            : latency < 500
                ? AppTheme.warning
                : AppTheme.error;
    final text = isTimeout ? '超时' : '${latency}ms';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 15 / 255),
          borderRadius: BorderRadius.circular(6)),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _TutorialStep extends StatelessWidget {
  final String step;
  final String text;
  const _TutorialStep({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: (isDark ? 30 : 20) / 255),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(step,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primary)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

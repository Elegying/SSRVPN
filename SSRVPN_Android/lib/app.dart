import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show
        AppConstants,
        AppLogger,
        AppModalCoordinator,
        AppUpdateInfo,
        HomeNodeController,
        SsrvpnAppBackdrop,
        SsrvpnBottomNavigation;
import 'package:ssrvpn_shared/widgets/crash_report_prompt.dart';
import 'services/settings_service.dart';
import 'services/clash_service.dart' as clash;
import 'services/subscription_service.dart';
import 'services/update_service.dart';
import 'screens/home_screen.dart';
import 'screens/subscription_screen.dart';

import 'startup/initialization_task.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_orchestrator.dart';
import 'theme/app_theme.dart';
import 'utils/responsive.dart';
import 'widgets/glass_container.dart';

class SSRVpnApp extends StatefulWidget {
  final StartupFlags startupFlags;
  const SSRVpnApp({super.key, this.startupFlags = const StartupFlags()});
  @override
  State<SSRVpnApp> createState() => _SSRVpnAppState();
}

class _SSRVpnAppState extends State<SSRVpnApp> {
  int _currentIndex = 0;
  late final PageController _pageController;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _appInitialized = false;
  bool _initError = false;
  String _initErrorMsg = '';
  // 不能用 late final：初始化中途失败后点"重试"会二次赋值直接抛 LateInitializationError
  SettingsService? _settingsService;
  clash.ClashService? _clashService;
  SubscriptionService? _subscriptionService;
  final InitializationTask _appInitialization = InitializationTask();
  final InitializationTask _coreInitialization = InitializationTask();
  AppUpdateInfo? _pendingStartupUpdate;
  bool _startupUpdatePresentationScheduled = false;
  Timer? _startupUpdateRetryTimer;

  // 公开 getter 供 StartupOrchestrator 使用
  clash.ClashService? get clashService => _clashService;
  SubscriptionService? get subscriptionService => _subscriptionService;

  /// HomeScreen key，用于页面切换时触发节点刷新
  final _homeKey = GlobalKey<HomeScreenState>();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    unawaited(_initApp());
  }

  @override
  void dispose() {
    _startupUpdateRetryTimer?.cancel();
    _pageController.dispose();
    final clashService = _clashService;
    if (clashService != null) unawaited(clashService.stop());
    super.dispose();
  }

  int _initRetryCount = 0;
  static const int _maxInitRetries = 2; // 首次 + 1次自动重试

  Future<void> _initApp() => _appInitialization.run(_performInitialization);

  Future<void> _performInitialization() async {
    while (mounted) {
      try {
        _settingsService ??= await SettingsService.getInstance();
        _clashService ??= clash.ClashService();
        await _coreInitialization
            .run(() => _clashService!.init(_settingsService!.settings))
            .timeout(
              const Duration(seconds: 90),
              onTimeout: () => throw TimeoutException('核心服务初始化超时（90秒）'),
            );
        final appDataDir = _clashService!.configDir;
        _subscriptionService =
            await SubscriptionService.getInstance(appDataDir).timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException('订阅服务初始化超时（30秒）'),
        );
        _initRetryCount = 0;
        if (!mounted) return;
        setState(() => _appInitialized = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(
            StartupOrchestrator(
              flags: widget.startupFlags,
              onUpdateAvailable: _queueStartupUpdate,
            ).start(),
          );
        });
        return;
      } catch (e) {
        _initRetryCount++;
        if (_initRetryCount < _maxInitRetries && mounted) {
          AppLogger.warning('SSRVPN', '初始化失败，自动重试 (第$_initRetryCount次)');
          await Future<void>.delayed(const Duration(seconds: 2));
          if (!mounted) return;
          setState(() {
            _initError = false;
            _initErrorMsg = '';
          });
          continue;
        }
        if (mounted) {
          setState(() {
            _initError = true;
            _initErrorMsg =
                '${e.toString().replaceFirst("Exception: ", "")}\n\n自动重试 $_initRetryCount 次后仍失败';
          });
        }
        return;
      }
    }
  }

  Future<void> _queueStartupUpdate(AppUpdateInfo update) async {
    if (!mounted) return;
    _pendingStartupUpdate = update;
    _scheduleStartupUpdatePresentation();
  }

  void _scheduleStartupUpdatePresentation() {
    if (_startupUpdatePresentationScheduled || !mounted) return;
    _startupUpdatePresentationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _startupUpdatePresentationScheduled = false;
      if (!mounted) return;
      final update = _pendingStartupUpdate;
      final updateContext = _navigatorKey.currentContext;
      if (update == null) return;
      if (updateContext == null) {
        _retryStartupUpdatePresentation();
        return;
      }
      if (UpdateService.isUpdateUiBusy) {
        _retryStartupUpdatePresentation();
        return;
      }
      try {
        await UpdateService.showUpdateDialog(
          updateContext,
          latestVersion: update.version,
          currentVersion: UpdateService.appVersion,
          downloadUrl: update.downloadUrl,
          changelog: update.changelog,
          sha256: update.sha256,
          fallbackDownloadUrl: update.fallbackDownloadUrl,
        );
        if (identical(_pendingStartupUpdate, update)) {
          _pendingStartupUpdate = null;
        }
      } catch (error, stackTrace) {
        AppLogger.warning(
          'Update',
          '启动更新提示暂时无法显示: $error\n$stackTrace',
        );
        _retryStartupUpdatePresentation();
      }
    });
  }

  void _retryStartupUpdatePresentation() {
    if (!mounted || _pendingStartupUpdate == null) return;
    _startupUpdateRetryTimer?.cancel();
    _startupUpdateRetryTimer = Timer(const Duration(seconds: 1), () {
      _startupUpdateRetryTimer = null;
      _scheduleStartupUpdatePresentation();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_initError) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: Scaffold(
          backgroundColor: const Color(0xFF0B0D14),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor.withValues(alpha: 20 / 255),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.error_outline,
                        size: 32, color: AppTheme.errorColor),
                  ),
                  const SizedBox(height: 20),
                  const Text('初始化失败',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.darkTextPrimary)),
                  const SizedBox(height: 8),
                  Text(_initErrorMsg,
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.darkTextSecondary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: 120,
                    height: 44,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _initRetryCount = 0;
                          _initError = false;
                          _initErrorMsg = '';
                          _appInitialized = false;
                        });
                        unawaited(_initApp());
                      },
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                      child: const Text('重试',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (!_appInitialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const Scaffold(
          backgroundColor: Color(0xFF0B0D14),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: AppTheme.primaryColor)),
                SizedBox(height: 20),
                Text('SSRVPN',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.darkTextPrimary,
                        letterSpacing: 1)),
                SizedBox(height: 8),
                Text('正在初始化...',
                    style: TextStyle(
                        fontSize: 14, color: AppTheme.darkTextSecondary)),
              ],
            ),
          ),
        ),
      );
    }

    return MultiProvider(
      providers: [
        // 只注册 ChangeNotifierProvider，避免重复注册
        ChangeNotifierProvider<SettingsService>.value(value: _settingsService!),
        Provider<clash.ClashService>.value(value: _clashService!),
        ChangeNotifierProvider<SubscriptionService>.value(
            value: _subscriptionService!),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'SSRVPN',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: CrashReportPrompt(
          child: _InitialSubscriptionPrompt(child: _buildMainScreen()),
        ),
      ),
    );
  }

  Widget _buildMainScreen() {
    return Builder(
      builder: (context) {
        Responsive.init(context);
        return SsrvpnAppBackdrop(
          child: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (i) {
                    setState(() => _currentIndex = i);
                    if (i == 0) _homeKey.currentState?.refreshNodes();
                  },
                  children: <Widget>[
                    HomeScreen(key: _homeKey),
                    const SubscriptionScreen(),
                  ],
                ),
              ),
              SsrvpnBottomNavigation(
                currentIndex: _currentIndex,
                version: AppConstants.appVersion,
                onTap: (i) {
                  if (i == 0) _homeKey.currentState?.refreshNodes();
                  setState(() => _currentIndex = i);
                  _pageController.animateToPage(
                    i,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _InitialSubscriptionPrompt extends StatefulWidget {
  final Widget child;

  const _InitialSubscriptionPrompt({required this.child});

  @override
  State<_InitialSubscriptionPrompt> createState() =>
      _InitialSubscriptionPromptState();
}

class _InitialSubscriptionPromptState
    extends State<_InitialSubscriptionPrompt> {
  bool _promptInFlight = false;
  int _lastPromptRevision = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  Future<void> _maybePrompt() async {
    if (_promptInFlight || !mounted) return;
    final subService = context.read<SubscriptionService>();
    if (HomeNodeController.runnableNodesFrom(subService.allNodes).isNotEmpty) {
      return;
    }
    if (_lastPromptRevision == subService.revision) return;

    _promptInFlight = true;
    _lastPromptRevision = subService.revision;
    String? input;
    try {
      input = await AppModalCoordinator.run<String?>(() {
        if (!mounted) return Future.value();
        return showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _InitialSubscriptionDialog(
            isValidInput: _isValidSubscriptionInput,
          ),
        );
      });
    } catch (error, stack) {
      AppLogger.warning(
        'Subscription',
        '初始订阅提示暂时无法显示: $error\n$stack',
      );
      return;
    } finally {
      _promptInFlight = false;
    }

    if (input == null || input.trim().isEmpty || !mounted) return;
    await _addSubscriptionAndRefresh(input.trim());
  }

  bool _isValidSubscriptionInput(String value) {
    if (value.isEmpty) return false;
    final subService = context.read<SubscriptionService>();
    if (subService.isSingleNodeLink(value)) return true;
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasAuthority &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  Future<void> _addSubscriptionAndRefresh(String value) async {
    final subService = context.read<SubscriptionService>();
    try {
      if (!subService.subscriptions.any((sub) => sub.url == value)) {
        await subService.addSubscription(
          subService.defaultSubscriptionName(value),
          value,
        );
      }

      final yaml = await subService.refreshAllSubscriptions();
      if (!mounted) return;

      final nodeCount =
          HomeNodeController.runnableNodesFrom(subService.allNodes).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Text(
            yaml != null && yaml.isNotEmpty
                ? '订阅成功，获取到 $nodeCount 个节点'
                : '订阅已添加，但未获取到节点',
          ),
          backgroundColor:
              nodeCount > 0 ? AppTheme.successColor : AppTheme.warningColor,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: const Text('订阅更新失败，请检查网络后重试'),
          backgroundColor: AppTheme.errorColor,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _InitialSubscriptionDialog extends StatefulWidget {
  final bool Function(String value) isValidInput;

  const _InitialSubscriptionDialog({required this.isValidInput});

  @override
  State<_InitialSubscriptionDialog> createState() =>
      _InitialSubscriptionDialogState();
}

class _InitialSubscriptionDialogState
    extends State<_InitialSubscriptionDialog> {
  final _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: GlassContainer(
        borderRadius: 16,
        enablePress: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.88,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            AppTheme.primaryColor,
                            AppTheme.accentColor,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.rss_feed_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '添加订阅',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '请粘贴你的SSR代码或订阅链接',
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  keyboardType: TextInputType.url,
                  decoration: GlassInputDecoration(
                    isDark: isDark,
                    hintText: 'ssr:// 或 https://...',
                    prefixIcon: const Icon(Icons.link, size: 20),
                  ).copyWith(errorText: _errorText),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('稍后'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          final value = _controller.text.trim();
                          if (!widget.isValidInput(value)) {
                            setState(() {
                              _errorText = '请输入有效的 SSR 代码或订阅链接';
                            });
                            return;
                          }
                          Navigator.pop(context, value);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
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

# SSRVPN 代码去重路线图

## 现状
三个平台 20 个核心文件各有独立版本（3 种不同 hash），唯一共享的是 `unlock_test_service.dart`。

## 已完成
- [x] 提取 `unlock_test_service.dart` → `packages/ssrvpn_shared/`
- [x] 三平台 `pubspec.yaml` 添加 path 依赖

## 接下来（按优先级）

### Phase 1: 数据模型去重 ✅ DONE (2026-06-26)
- [x] `models/proxy_node.dart` → shared (macOS 增强版，含 isTimedOut/effectiveLatency)
- [x] `models/proxy_group.dart` → shared
- [x] `models/subscription.dart` → shared
- [ ] `models/app_settings.dart` — 差异在平台特有设置项，暂缓

### Phase 2: UI 组件去重
- `widgets/glass_container.dart` — 视觉逻辑一致
- `widgets/liquid_glass.dart` — Android 独有 shader
- `widgets/connection_button.dart` — macOS/Windows 一致
- `theme/app_theme.dart` — 颜色/字体主题

### Phase 3: 服务层抽象
- `services/clash_service.dart` — 抽 ClashServiceBase 抽象类
- `services/subscription_service.dart` — 抽 SubscriptionServiceBase
- `services/subscription_service.dart` — Android 额外 SSR 链接解析可提取为 mixin
- `services/settings_service.dart` — 抽 SettingsServiceBase

### Phase 4: 屏幕层去重
- `screens/home_screen.dart` — 各平台 UI 布局不同（移动端 vs 桌面），部分业务逻辑可共享
- `screens/subscription_screen.dart` — 同上

## 去重策略
1. **Base class extraction**: 创建抽象基类，平台实现具体逻辑
2. **Mixin**: UI 行为 (loading, error handling) 抽为 mixin
3. **Configurable widget**: 参数化差异部分而非 fork 整个文件
4. **Platform channel abstraction**: 平台原生调用统一接口

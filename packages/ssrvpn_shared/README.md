# ssrvpn_shared

`ssrvpn_shared` 是 SSRVPN 三端共用的 Dart/Flutter 业务逻辑包。Android、macOS 和 Windows 应用都通过本地 path 依赖使用它，避免每个平台重复维护订阅解析、节点模型、配置生成和安全脱敏逻辑。

## 包含内容

- `models/`：代理节点、代理组、订阅和应用设置等数据结构。
- `services/`：订阅解析、SSR 链接导入、Clash/Mihomo 配置生成和更新检查等基础服务。
- `utils/`：日志脱敏、强制代理站点策略、私有节点延迟策略等通用工具。
- `constants/`：默认端口、超时时间和应用级常量。
- `test/`：订阅解析、配置生成、策略和脱敏行为的单元测试。

## 在平台应用中使用

在平台应用的 `pubspec.yaml` 中通过本地路径引用：

```yaml
dependencies:
  ssrvpn_shared:
    path: ../packages/ssrvpn_shared
```

导入统一出口文件：

```dart
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
```

## 常见用法

创建代理节点：

```dart
final node = ProxyNode(
  name: 'My Node',
  type: 'ss',
  server: 'example.com',
  port: 443,
  group: 'All Nodes',
);
```

创建应用设置：

```dart
final settings = AppSettings(
  proxyPort: 7890,
  socksPort: 7891,
  apiPort: 9090,
);
```

解析订阅并生成 Clash/Mihomo 配置：

```dart
final subscription = SubscriptionParser.parseYaml(yamlContent);

final config = ClashConfigGenerator.generateConfig(
  yamlContent,
  settings,
  preferredNodeName: subscription.nodes.first.name,
);
```

导入单条 SSR 链接：

```dart
final ssrYaml = SubscriptionParser.importSsrLink('ssr://...');
```

## 本地验证

```bash
dart pub get
dart analyze
dart test
```

如需覆盖率：

```bash
flutter test --coverage
```

## 开发约定

- 新增可复用业务逻辑时优先放在本包，再由平台应用调用。
- 平台专属 UI、系统代理、TUN、托盘、安装包和权限流程保留在各平台目录。
- 订阅 URL、API secret、密码、Bearer token 和代理凭据必须走脱敏逻辑，不能直接写入日志。
- 修改解析、配置生成或策略行为时必须补充对应测试。

## 许可证

MIT License，详见仓库根目录 `LICENSE`。

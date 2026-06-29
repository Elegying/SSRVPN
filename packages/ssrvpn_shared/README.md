# SSRVPN Shared Package

Shared models, services, and utilities for SSRVPN cross-platform clients.

## Overview

This package contains the core business logic shared across Android, macOS, and Windows platforms. It includes:

- **Models**: Data structures for proxy nodes, groups, subscriptions, and app settings
- **Services**: Core services for subscription parsing and Clash configuration generation
- **Utils**: Utility classes for logging, proxy policies, and latency handling
- **Constants**: Application-wide constants and configuration values

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  ssrvpn_shared:
    path: ../packages/ssrvpn_shared
```

## Usage

### Importing

```dart
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
```

### Models

```dart
// Create a proxy node
final node = ProxyNode(
  name: 'My Node',
  type: 'ss',
  server: 'example.com',
  port: 443,
  group: 'All Nodes',
);

// Create app settings
final settings = AppSettings(
  proxyPort: 7890,
  socksPort: 7891,
  apiPort: 9090,
);
```

### Services

```dart
// Parse subscription YAML
final subscription = SubscriptionParser.parseYaml(yamlContent);
print('Found ${subscription.nodes.length} nodes');

// Import SSR link
final ssrYaml = SubscriptionParser.importSsrLink('ssr://...');

// Generate Clash config
final config = ClashConfigGenerator.generateConfig(
  yamlContent,
  settings,
  preferredNodeName: 'My Node',
);
```

### Constants

```dart
// Use predefined constants
print('Default proxy port: ${AppConstants.defaultProxyPort}');
print('Health check timeout: ${AppConstants.healthCheckTimeout}');
```

## Testing

Run tests:

```bash
dart test
```

Run tests with coverage:

```bash
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info
```

## Architecture

The package follows a clean architecture pattern:

```
lib/
├── models/          # Data structures
├── services/        # Business logic
├── utils/           # Utility classes
├── constants/       # Application constants
└── ssrvpn_shared.dart  # Barrel file
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Run tests to ensure everything works
6. Submit a pull request

## License

MIT License - see [LICENSE](../../LICENSE) for details.

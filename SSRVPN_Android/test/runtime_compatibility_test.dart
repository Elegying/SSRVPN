import 'package:ssrvpn_android/services/clash_service.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';

import '../../packages/ssrvpn_shared/test/support/runtime_compatibility.dart';

void main() {
  final core = ClashService();
  registerRuntimeCompatibilityTests(
    openSubscription: (directory) => SubscriptionService.getInstance(directory),
    resetSubscription: SubscriptionService.resetInstanceForTesting,
    generate: core.generateClashConfig,
    generateAsync: core.generateClashConfigAsync,
  );
}

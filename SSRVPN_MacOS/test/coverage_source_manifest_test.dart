// This file loads every standalone production library so LCOV can account for
// untested executable lines. Local `part` files load through their owner.
// ignore_for_file: unused_import

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/app.dart';
import 'package:ssrvpn_macos/main.dart';
import 'package:ssrvpn_macos/models/app_settings.dart';
import 'package:ssrvpn_macos/screens/home_screen.dart';
import 'package:ssrvpn_macos/screens/node_edit_screen.dart';
import 'package:ssrvpn_macos/screens/subscription_screen.dart';
import 'package:ssrvpn_macos/services/clash_service.dart';
import 'package:ssrvpn_macos/services/direct_fetcher.dart';
import 'package:ssrvpn_macos/services/ip_geo_service.dart';
import 'package:ssrvpn_macos/services/macos_tun_session.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';
import 'package:ssrvpn_macos/services/subscription_service.dart';
import 'package:ssrvpn_macos/services/system_proxy_service.dart';
import 'package:ssrvpn_macos/services/tray_manager.dart';
import 'package:ssrvpn_macos/services/update_service.dart';
import 'package:ssrvpn_macos/src/services/system_proxy_ownership.dart';
import 'package:ssrvpn_macos/startup/startup_flags.dart';
import 'package:ssrvpn_macos/startup/startup_logger.dart';
import 'package:ssrvpn_macos/startup/startup_orchestrator.dart';
import 'package:ssrvpn_macos/startup/startup_status.dart';
import 'package:ssrvpn_macos/startup/window_state_store.dart';
import 'package:ssrvpn_macos/theme/app_theme.dart';
import 'package:ssrvpn_macos/utils/responsive.dart';
import 'package:ssrvpn_macos/widgets/connection_button.dart';
import 'package:ssrvpn_macos/widgets/glass_container.dart';
import 'package:ssrvpn_macos/widgets/liquid_glass.dart';

void main() {
  test('loads the auditable production source manifest', () {
    expect(true, isTrue);
  });
}

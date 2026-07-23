// This file loads every standalone production library so LCOV can account for
// untested executable lines. Local `part` files load through their owner.
// ignore_for_file: unused_import

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/app.dart';
import 'package:ssrvpn_windows/main.dart';
import 'package:ssrvpn_windows/models/app_settings.dart';
import 'package:ssrvpn_windows/screens/home_screen.dart';
import 'package:ssrvpn_windows/screens/node_edit_screen.dart';
import 'package:ssrvpn_windows/screens/subscription_screen.dart';
import 'package:ssrvpn_windows/services/app_shutdown.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/services/ip_geo_service.dart';
import 'package:ssrvpn_windows/services/settings_service.dart';
import 'package:ssrvpn_windows/services/subscription_service.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';
import 'package:ssrvpn_windows/services/tray_manager.dart';
import 'package:ssrvpn_windows/services/update_service.dart';
import 'package:ssrvpn_windows/services/windows_desktop_directory.dart';
import 'package:ssrvpn_windows/services/windows_dpapi_secret_store.dart';
import 'package:ssrvpn_windows/services/windows_tun_elevation_service.dart';
import 'package:ssrvpn_windows/services/windows_tun_runtime_probe.dart';
import 'package:ssrvpn_windows/src/services/system_proxy_ownership.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';
import 'package:ssrvpn_windows/startup/startup_flags.dart';
import 'package:ssrvpn_windows/startup/startup_logger.dart';
import 'package:ssrvpn_windows/startup/startup_orchestrator.dart';
import 'package:ssrvpn_windows/startup/startup_status.dart';
import 'package:ssrvpn_windows/startup/window_state_store.dart';
import 'package:ssrvpn_windows/theme/app_theme.dart';
import 'package:ssrvpn_windows/utils/responsive.dart';
import 'package:ssrvpn_windows/widgets/glass_container.dart';

void main() {
  test('loads the auditable production source manifest', () {
    expect(true, isTrue);
  });
}

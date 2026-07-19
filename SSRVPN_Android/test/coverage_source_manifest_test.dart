// This file loads every standalone production library so LCOV can account for
// untested executable lines. Local `part` files load through their owner.
// ignore_for_file: unused_import

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/app.dart';
import 'package:ssrvpn_android/main.dart';
import 'package:ssrvpn_android/models/app_settings.dart';
import 'package:ssrvpn_android/screens/home_connection_status_policy.dart';
import 'package:ssrvpn_android/screens/home_screen.dart';
import 'package:ssrvpn_android/screens/node_edit_screen.dart';
import 'package:ssrvpn_android/screens/subscription_screen.dart';
import 'package:ssrvpn_android/services/clash_service.dart';
import 'package:ssrvpn_android/services/connection_orchestrator.dart';
import 'package:ssrvpn_android/services/http_client_adapter.dart';
import 'package:ssrvpn_android/services/settings_service.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';
import 'package:ssrvpn_android/services/update_service.dart';
import 'package:ssrvpn_android/startup/initialization_task.dart';
import 'package:ssrvpn_android/startup/startup_flags.dart';
import 'package:ssrvpn_android/startup/startup_logger.dart';
import 'package:ssrvpn_android/startup/startup_orchestrator.dart';
import 'package:ssrvpn_android/startup/startup_status.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
import 'package:ssrvpn_android/utils/responsive.dart';
import 'package:ssrvpn_android/widgets/connection_button.dart';
import 'package:ssrvpn_android/widgets/force_proxy_sites_dialog.dart';
import 'package:ssrvpn_android/widgets/glass_container.dart';
import 'package:ssrvpn_android/widgets/home_node_list.dart';
import 'package:ssrvpn_android/widgets/liquid_glass.dart';
import 'package:ssrvpn_android/widgets/node_list_tile.dart';
import 'package:ssrvpn_android/widgets/proxy_mode_selector.dart';
import 'package:ssrvpn_android/widgets/subscription_screen_sections.dart';

void main() {
  test('loads the auditable production source manifest', () {
    expect(true, isTrue);
  });
}

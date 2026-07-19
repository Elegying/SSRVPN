// This file loads every standalone production library so LCOV can account for
// untested executable lines. Local `part` files load through their owner.
// ignore_for_file: unused_import

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/controllers/home_exit_country_controller.dart';
import 'package:ssrvpn_shared/controllers/home_latency_controller.dart';
import 'package:ssrvpn_shared/controllers/home_node_controller.dart';
import 'package:ssrvpn_shared/controllers/subscription_screen_controller.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_group.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/models/public_ip_info.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import 'package:ssrvpn_shared/services/crash_reporter.dart';
import 'package:ssrvpn_shared/services/desktop_connection_coordinator.dart';
import 'package:ssrvpn_shared/services/desktop_subscription_fetcher.dart';
import 'package:ssrvpn_shared/services/direct_fetcher.dart';
import 'package:ssrvpn_shared/services/public_ip_info_service.dart';
import 'package:ssrvpn_shared/services/subscription_header_name_parser.dart';
import 'package:ssrvpn_shared/services/subscription_node_codec.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/services/subscription_processing.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_result.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/services/subscription_text_decoder.dart';
import 'package:ssrvpn_shared/services/subscription_yaml_merger.dart';
import 'package:ssrvpn_shared/services/timed_process_runner.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:ssrvpn_shared/services/update_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/utils/app_logger.dart';
import 'package:ssrvpn_shared/utils/async_lazy.dart';
import 'package:ssrvpn_shared/utils/best_effort_cleanup.dart';
import 'package:ssrvpn_shared/utils/bounded_file_logger.dart';
import 'package:ssrvpn_shared/utils/bounded_yaml.dart';
import 'package:ssrvpn_shared/utils/connection_intent_tracker.dart';
import 'package:ssrvpn_shared/utils/core_recovery_policy.dart';
import 'package:ssrvpn_shared/utils/desktop_startup_file_logger.dart';
import 'package:ssrvpn_shared/utils/desktop_window_state_store.dart';
import 'package:ssrvpn_shared/utils/force_proxy_site_policy.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';
import 'package:ssrvpn_shared/utils/node_country_policy.dart';
import 'package:ssrvpn_shared/utils/node_display_policy.dart';
import 'package:ssrvpn_shared/utils/private_node_latency_policy.dart';
import 'package:ssrvpn_shared/utils/proxy_node_usage_policy.dart';
import 'package:ssrvpn_shared/utils/recovering_serial_queue.dart';
import 'package:ssrvpn_shared/utils/subscription_url_policy.dart';
import 'package:ssrvpn_shared/widgets/app_diagnostics_view.dart';
import 'package:ssrvpn_shared/widgets/app_title_with_version.dart';
import 'package:ssrvpn_shared/widgets/country_flag_icon.dart';
import 'package:ssrvpn_shared/widgets/crash_report_prompt.dart';

void main() {
  test('loads the auditable production source manifest', () {
    expect(true, isTrue);
  });
}

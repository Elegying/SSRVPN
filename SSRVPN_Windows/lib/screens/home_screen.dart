// ignore_for_file: unnecessary_library_name

library desktop_home_screen;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_button.dart';
import '../widgets/glass_container.dart';
import '../widgets/liquid_glass.dart';
import 'node_edit_screen.dart';

import '../startup/startup_logger.dart';

part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_screen_part.dart';
part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_runtime_actions_part.dart';
part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_public_ip_part.dart';
part 'package:ssrvpn_shared/desktop_ui/widgets/desktop_force_proxy_sites_dialog_part.dart';
part 'package:ssrvpn_shared/desktop_ui/widgets/desktop_home_dashboard_part.dart';
part 'package:ssrvpn_shared/desktop_ui/widgets/desktop_home_dialogs_part.dart';
part 'package:ssrvpn_shared/desktop_ui/widgets/desktop_home_node_list_part.dart';

const String desktopPlatformLabel = 'Windows';

void recordDesktopConnectionFailure(
  String message, {
  Object? error,
  StackTrace? stack,
}) {
  StartupLogger.writeDesktopFailureReportSync(
    message,
    error: error,
    stack: stack,
  );
  CrashReporter.recordSync(message, error ?? message, stack);
}

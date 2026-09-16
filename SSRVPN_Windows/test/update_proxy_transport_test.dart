import 'dart:io';
import 'package:ssrvpn_windows/services/update_service.dart';

// Run the shared real CONNECT/TLS cases on the native desktop CI runner too.
import '../../packages/ssrvpn_shared/test/update_proxy_transport_test.dart'
    as shared;

void main() => shared.main(
    filePublisher:
        Platform.isWindows ? UpdateService.publishVerifiedInstaller : null);

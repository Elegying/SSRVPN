part of 'clash_service_base.dart';

extension ClashNetworkVerification on ClashServiceBase {
  NetworkVerification get networkVerification {
    final at = _dataPlaneResultAt;
    return NetworkVerification(
      state: at == null
          ? NetworkVerificationState.pending
          : _dataPlaneVerified
              ? NetworkVerificationState.verified
              : NetworkVerificationState.unverified,
      checkedAt: at,
      requestMilliseconds: dataPlaneRequestMilliseconds,
      errorCode: dataPlaneRequestCode,
    );
  }
}

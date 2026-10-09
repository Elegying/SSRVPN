part of 'clash_service_base.dart';

extension ClashNetworkVerification on ClashServiceBase {
  NetworkVerification get networkVerification {
    final at = _dataPlaneResultAt;
    final age = at == null ? null : DateTime.now().difference(at);
    final current =
        age != null && !age.isNegative && age <= const Duration(hours: 1);
    return NetworkVerification(
      state: at == null
          ? NetworkVerificationState.pending
          : current && _dataPlaneConnectivityWarning == null
              ? NetworkVerificationState.verified
              : NetworkVerificationState.unverified,
      checkedAt: at,
      requestMilliseconds: dataPlaneRequestMilliseconds,
      errorCode: dataPlaneRequestCode,
    );
  }
}

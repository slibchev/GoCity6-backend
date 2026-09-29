import 'external_ride_session.dart';

enum AtomicExternalRideStartOfferResolution { none, becameBusy, expired }

enum AtomicExternalRideConflict {
  activeShiftNotFound,
  driverNotAvailable,
  driverNotOnExternalRide,
  queueStateMismatch,
  activeExternalRideExists,
  activeExternalRideNotFound,
}

class AtomicExternalRideConflictException implements Exception {
  final AtomicExternalRideConflict conflict;

  const AtomicExternalRideConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic external ride conflict: ${conflict.name}';
  }
}

class AtomicExternalRideStartResult {
  final ExternalRideSession session;

  final AtomicExternalRideStartOfferResolution offerResolution;

  final String? resolvedOfferId;
  final String? resolvedRideId;

  const AtomicExternalRideStartResult({
    required this.session,
    required this.offerResolution,
    required this.resolvedOfferId,
    required this.resolvedRideId,
  });
}

class AtomicExternalRideFinishResult {
  final ExternalRideSession session;

  /// true само когато:
  ///
  /// - "Зает" е натиснат при валидна City6 offer;
  /// - external ride е приключил под 500 метра.
  ///
  /// Самото начисляване на бъдеща санкция НЕ е отговорност
  /// на този repository.
  final bool shouldCountTriggeredOfferAsRejection;

  final String? triggerOfferId;
  final String? triggerRideId;

  const AtomicExternalRideFinishResult({
    required this.session,
    required this.shouldCountTriggeredOfferAsRejection,
    required this.triggerOfferId,
    required this.triggerRideId,
  });
}

abstract interface class AtomicExternalRideRepository {
  /// Атомарно изпълнява бутона "Зает".
  Future<AtomicExternalRideStartResult> startExternalRide({
    required String sessionId,
    required String driverId,
    required DateTime now,
  });

  /// Атомарно изпълнява бутона "Свободен".
  ///
  /// В една транзакция:
  /// - заключва активната смяна и queue state;
  /// - изисква availability == externalRide;
  /// - заключва активната ExternalRideSession;
  /// - приключва session-а;
  /// - availability -> available;
  /// - queuePrioritySince -> now;
  /// - has_pending_offer остава false;
  /// - връща дали trigger offer трябва по-късно да се брои за отказ.
  Future<AtomicExternalRideFinishResult> finishExternalRide({
    required String driverId,
    required DateTime now,
  });
}

import 'external_ride_session.dart';

enum AtomicExternalRideStartOfferResolution { none, becameBusy, expired }

enum AtomicExternalRideConflict {
  activeShiftNotFound,
  driverNotAvailable,
  queueStateMismatch,
  activeExternalRideExists,
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

  /// Какво се случи с City6 offer-а в момента на натискане на "Зает".
  ///
  /// none:
  ///   Няма активна offer.
  ///
  /// becameBusy:
  ///   Имало е валидна pending offer. Тя е приключена като rejected,
  ///   а external ride session пази triggerOfferId + triggerRideId.
  ///   След края на курса правилото за 500 м ще реши дали това
  ///   се отчита като отказ.
  ///
  /// expired:
  ///   Имало е pending offer, но срокът й вече е бил изтекъл.
  ///   Тя се приключва като expired и НЕ се използва като trigger
  ///   за 500-метровото правило.
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

abstract interface class AtomicExternalRideRepository {
  /// Атомарно изпълнява бутона "Зает".
  ///
  /// В една PostgreSQL транзакция трябва да:
  /// - заключи текущото queue състояние;
  /// - предотврати нова automatic offer;
  /// - приключи текущата pending offer, ако има такава;
  /// - смени availability на externalRide;
  /// - изчисти has_pending_offer;
  /// - създаде ExternalRideSession.
  ///
  /// queuePrioritySince НЕ се променя тук.
  /// При връщане на "Свободен" шофьорът ще получи NOW и ще
  /// влезе отзад в опашката на текущия район.
  Future<AtomicExternalRideStartResult> startExternalRide({
    required String sessionId,
    required String driverId,
    required DateTime now,
  });
}

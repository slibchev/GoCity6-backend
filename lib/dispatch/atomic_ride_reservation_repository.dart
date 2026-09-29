import 'ride_reservation.dart';

enum AtomicRideReservationConflict {
  rideNotFound,
  rideNotWaitingForVehicle,
  rideAlreadyAssigned,

  activeShiftNotFound,
  driverNotReservable,
  queueStateMismatch,

  currentCity6RideNotFound,

  activeExternalRideNotFound,
  externalRideNotQualified,

  etaTooHigh,

  rideAlreadyReserved,
  driverAlreadyHasReservedRide,
  vehicleAlreadyHasReservedRide,
}

class AtomicRideReservationConflictException implements Exception {
  final AtomicRideReservationConflict conflict;

  const AtomicRideReservationConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic ride reservation conflict: ${conflict.name}';
  }
}

abstract interface class AtomicRideReservationRepository {
  static const int maximumCombinedEtaSeconds = 600;

  /// Атомарно резервира waiting-board поръчка като следваща
  /// поръчка за зает шофьор.
  ///
  /// [combinedEtaSeconds] трябва да бъде изчислено от backend-а,
  /// а не да бъде доверено на Flutter клиента.
  ///
  /// За City6 busy driver:
  ///   remaining current City6 ride ETA
  ///   + route ETA from current destination to next pickup.
  ///
  /// За externalRide driver:
  ///   route ETA from current verified GPS position to next pickup.
  ///
  /// Repository-ът трябва в една транзакция да:
  /// - заключи target ride;
  /// - изисква status == waitingForVehicle;
  /// - заключи active driver shift + queue state;
  /// - допуска само busy или externalRide;
  /// - гарантира, че няма друга активна reservation за driver-а;
  /// - при externalRide да заключи active external session;
  /// - при externalRide да изисква >= 500 verified meters;
  /// - изисква combined ETA <= 600 seconds;
  /// - създаде active RideReservation;
  /// - промени ride status waitingForVehicle -> reserved.
  ///
  /// assigned_driver_id и assigned_vehicle_id НЕ се попълват тук.
  ///
  /// Reservation-ът е "следваща поръчка", а не текущо accepted ride.
  Future<RideReservation> reserveWaitingRide({
    required String reservationId,
    required String rideId,
    required String driverId,
    required int combinedEtaSeconds,
    required DateTime now,
  });
}

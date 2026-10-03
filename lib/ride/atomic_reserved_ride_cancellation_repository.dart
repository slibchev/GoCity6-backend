import 'ride_request.dart';

enum AtomicReservedRideCancellationConflict {
  reservedRideNotFound,
  reservedRideNotReserved,
  activeReservationNotFound,
  reservationStateMismatch,
  activeShiftNotFound,
  queueStateMismatch,
  currentCity6RideNotFound,
  activeExternalRideNotFound,
}

class AtomicReservedRideCancellationConflictException implements Exception {
  final AtomicReservedRideCancellationConflict conflict;

  const AtomicReservedRideCancellationConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic reserved ride cancellation conflict: ${conflict.name}';
  }
}

/// PostgreSQL-capable cancellation path for a reserved next ride.
///
/// The reserved ride has no assigned_driver_id / assigned_vehicle_id.
/// Ownership is represented by the active ride_reservations row.
///
/// The operation must:
///   1. identify the active reservation;
///   2. lock active shift + queue;
///   3. validate the driver's current busy/externalRide state;
///   4. lock and revalidate the active reservation;
///   5. lock and revalidate the reserved ride;
///   6. move reserved ride -> cancelled;
///   7. end the reservation.
///
/// The driver's queue availability remains unchanged because cancelling
/// the next reserved ride does not end the driver's current ride/session.
abstract interface class AtomicReservedRideCancellationRepository {
  Future<RideRequest> cancelReservedRide({
    required String rideId,
    required DateTime cancelledAt,
  });
}

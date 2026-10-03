import 'ride_request.dart';

enum AtomicRideCancellationConflict {
  currentRideNotFound,
  currentRideNotCancellable,
  currentRideAssignmentMismatch,
  activeShiftNotFound,
  queueStateMismatch,
  reservationStateMismatch,
  reservedRideStateMismatch,
}

class AtomicRideCancellationConflictException implements Exception {
  final AtomicRideCancellationConflict conflict;

  const AtomicRideCancellationConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic ride cancellation conflict: ${conflict.name}';
  }
}

/// PostgreSQL-capable atomic cancellation path for an assigned current ride.
///
/// Lock order:
///   1. active shift + queue
///   2. current City6 ride
///   3. active reservation, if any
///   4. reserved next ride, if any
///
/// If an active reservation exists:
///   current accepted/driverArriving -> cancelled
///   reserved next ride -> accepted
///   reservation -> ended
///   queue remains busy
///
/// If no active reservation exists:
///   current accepted/driverArriving -> cancelled
///   queue -> available
abstract interface class AtomicRideCancellationRepository {
  Future<RideRequest> cancelAssignedRideAndPromoteReservedRide({
    required RideRequest cancelledRide,
    required DateTime cancelledAt,
  });
}

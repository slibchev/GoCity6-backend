import 'ride_request.dart';

enum AtomicRideCompletionConflict {
  currentRideNotFound,
  currentRideNotInProgress,
  currentRideAssignmentMismatch,
  activeShiftNotFound,
  queueStateMismatch,
  reservationStateMismatch,
  reservedRideStateMismatch,
}

class AtomicRideCompletionConflictException implements Exception {
  final AtomicRideCompletionConflict conflict;

  const AtomicRideCompletionConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic ride completion conflict: ${conflict.name}';
  }
}

/// PostgreSQL-capable atomic completion path.
///
/// The caller supplies an already validated/computed completed ride.
/// The repository must re-check authoritative database state inside
/// the transaction before persisting it.
///
/// Lock order:
///   1. active shift + queue
///   2. current City6 ride
///   3. active reservation, if any
///   4. reserved next ride, if any
///
/// If an active reservation exists:
///   current inProgress -> completed
///   reserved next ride -> accepted
///   reservation -> ended
///   queue remains busy
///
/// If no active reservation exists:
///   current inProgress -> completed
///   queue -> available
abstract interface class AtomicRideCompletionRepository {
  Future<RideRequest> completeRideAndPromoteReservedRide({
    required RideRequest completedRide,
  });
}
import '../ride/ride_request.dart';

enum AtomicWaitingRideAcceptanceConflict {
  rideNotFound,
  rideNotWaitingForVehicle,
  rideAlreadyAssigned,
  activeShiftNotFound,
  driverNotAvailable,
  pendingOfferExists,
  queueStateMismatch,
}

class AtomicWaitingRideAcceptanceConflictException implements Exception {
  final AtomicWaitingRideAcceptanceConflict conflict;

  const AtomicWaitingRideAcceptanceConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic waiting ride acceptance conflict: ${conflict.name}';
  }
}

/// Atomically accepts a general-board waiting ride for a currently available
/// driver.
///
/// Lock order:
///   1. target ride
///   2. active shift + queue
///
/// On success:
///   waitingForVehicle -> accepted
///   assigned_driver_id / assigned_vehicle_id are populated
///   queue available -> busy
abstract interface class AtomicWaitingRideAcceptanceRepository {
  Future<RideRequest> acceptWaitingRide({
    required String rideId,
    required String driverId,
  });
}

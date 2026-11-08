import 'ride_request.dart';
import 'ride_request_status.dart';

abstract interface class RideRequestRepository {
  Future<RideRequest?> findById(String id);
  Future<RideRequest?> findByClientRequestId(String clientRequestId);

  Future<List<RideRequest>> findByAssignedDriverId(String driverId);
  Future<List<RideRequest>> findWaitingForVehicle();

  Future<void> save(RideRequest request);
}

/// Optional persistence capability for a pending ride that will enter
/// automatic dispatch. PostgreSQL implementations enqueue the durable
/// continuation in the same transaction as the ride insert.
abstract interface class DurableAutomaticDispatchSubmissionRepository {
  Future<void> savePendingRideForAutomaticDispatch(RideRequest request);
}

abstract interface class AtomicRideClaimRepository {
  Future<RideRequest?> claimWaitingRide({
    required String rideId,
    required String driverId,
    required String vehicleId,
    required RideRequestStatus targetStatus,
  });
}

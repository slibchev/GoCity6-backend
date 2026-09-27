import 'ride_request.dart';
import 'ride_request_status.dart';

abstract interface class RideRequestRepository {
  Future<RideRequest?> findById(String id);

  Future<List<RideRequest>> findByAssignedDriverId(
    String driverId,
  );

  Future<void> save(RideRequest request);
}

abstract interface class AtomicRideClaimRepository {
  Future<RideRequest?> claimWaitingRide({
    required String rideId,
    required String driverId,
    required String vehicleId,
    required RideRequestStatus targetStatus,
  });
}
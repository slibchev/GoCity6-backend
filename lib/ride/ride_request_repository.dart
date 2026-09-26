import 'ride_request.dart';

abstract interface class RideRequestRepository {
  Future<RideRequest?> findById(String id);

  Future<List<RideRequest>> findByAssignedDriverId(String driverId);

  Future<void> save(RideRequest request);
}

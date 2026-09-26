import 'ride_request.dart';
import 'ride_request_repository.dart';

class InMemoryRideRequestRepository implements RideRequestRepository {
  final Map<String, RideRequest> _rides = {};

  InMemoryRideRequestRepository([
    Iterable<RideRequest> initialRides = const <RideRequest>[],
  ]) {
    for (final ride in initialRides) {
      _rides[ride.id] = ride;
    }
  }

  @override
  Future<RideRequest?> findById(String id) async {
    return _rides[id];
  }

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {
    return _rides.values
        .where((ride) => ride.assignedDriverId == driverId)
        .toList(growable: false);
  }

  @override
  Future<void> save(RideRequest request) async {
    _rides[request.id] = request;
  }
}

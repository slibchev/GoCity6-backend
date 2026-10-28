import 'ride_request.dart';
import 'ride_request_repository.dart';
import 'ride_request_status.dart';

class InMemoryRideRequestRepository implements RideRequestRepository {
  final Map<String, RideRequest> _rides = {};
  final DateTime Function() clock;

  InMemoryRideRequestRepository([
    Iterable<RideRequest> initialRides = const <RideRequest>[],
  ]) : clock = DateTime.now {
    for (final ride in initialRides) {
      _rides[ride.id] = ride;
    }
  }

  InMemoryRideRequestRepository.withClock({
    Iterable<RideRequest> initialRides = const <RideRequest>[],
    required this.clock,
  }) {
    for (final ride in initialRides) {
      _rides[ride.id] = ride;
    }
  }

  @override
  Future<RideRequest?> findById(String id) async {
    return _rides[id];
  }

  @override
  Future<RideRequest?> findByClientRequestId(String clientRequestId) async {
    for (final ride in _rides.values) {
      if (ride.clientRequestId == clientRequestId) {
        return ride;
      }
    }
    return null;
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

  @override
  Future<List<RideRequest>> findWaitingForVehicle() async {
    final cutoff = clock().toUtc().subtract(const Duration(minutes: 30));
    final waiting = _rides.values
        .where(
          (ride) =>
              ride.status == RideRequestStatus.waitingForVehicle &&
              ride.assignedDriverId == null &&
              ride.assignedVehicleId == null &&
              ride.requestedAt.toUtc().isAfter(cutoff),
        )
        .toList();

    waiting.sort((a, b) {
      final byTime = a.requestedAt.compareTo(b.requestedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });

    return waiting;
  }
}

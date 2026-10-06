import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 6, 20);

  RideRequest buildRide() {
    return RideRequest(
      id: 'ride-001',
      pickup: 'Sofia Center',
      destination: 'Sofia Airport',
      passengers: 1,
      requestedAt: now,
    );
  }

  ActiveDriverShift buildShift({
    DriverQueueAvailability availability = DriverQueueAvailability.available,
    bool hasPendingOffer = false,
  }) {
    final queueState = DriverQueueState.restore(
      driverId: 'driver-001',
      queuePrioritySince: now.subtract(const Duration(minutes: 10)),
      availability: availability,
      shortBreaksUsed: 0,
      breakStartedAt: null,
      hasPendingOffer: hasPendingOffer,
    );

    return ActiveDriverShift.restore(
      id: 'shift-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      startedAt: now.subtract(const Duration(hours: 1)),
      queueState: queueState,
    );
  }

  test('builds candidate from available driver with fresh location', () async {
    final shiftRepository = _FakeDriverShiftRepository(shifts: [buildShift()]);

    final locationRepository = _FakeDriverLiveLocationRepository(
      locations: {
        'driver-001': DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.6977,
          longitude: 23.3219,
          updatedAt: now.subtract(const Duration(seconds: 10)),
        ),
      },
    );

    final routeEstimator = _FakeRouteEstimator(
      result: RouteEstimate(distanceMeters: 1250.4, durationSeconds: 245.6),
    );

    final service = DispatchCandidateService(
      shiftRepository: shiftRepository,
      liveLocationRepository: locationRepository,
      routeEstimator: routeEstimator,
    );

    final result = await service.buildForRide(ride: buildRide(), now: now);

    expect(result, hasLength(1));

    final candidate = result.single;

    expect(candidate.driverId, 'driver-001');
    expect(candidate.vehicleId, 'vehicle-001');
    expect(candidate.distanceMeters, 1250);
    expect(candidate.etaSeconds, 246);

    expect(routeEstimator.calls, 1);
    expect(routeEstimator.lastOrigin?.latitude, 42.6977);
    expect(routeEstimator.lastOrigin?.longitude, 23.3219);
    expect(routeEstimator.lastDestination?.address, 'Sofia Center');
  });

  test('skips driver without live location', () async {
    final routeEstimator = _FakeRouteEstimator(
      result: RouteEstimate(distanceMeters: 1000, durationSeconds: 200),
    );

    final service = DispatchCandidateService(
      shiftRepository: _FakeDriverShiftRepository(shifts: [buildShift()]),
      liveLocationRepository: _FakeDriverLiveLocationRepository(),
      routeEstimator: routeEstimator,
    );

    final result = await service.buildForRide(ride: buildRide(), now: now);

    expect(result, isEmpty);
    expect(routeEstimator.calls, 0);
  });

  test('skips driver with stale live location', () async {
    final routeEstimator = _FakeRouteEstimator(
      result: RouteEstimate(distanceMeters: 1000, durationSeconds: 200),
    );

    final service = DispatchCandidateService(
      shiftRepository: _FakeDriverShiftRepository(shifts: [buildShift()]),
      liveLocationRepository: _FakeDriverLiveLocationRepository(
        locations: {
          'driver-001': DriverLiveLocation(
            driverId: 'driver-001',
            latitude: 42.6977,
            longitude: 23.3219,
            updatedAt: now.subtract(const Duration(seconds: 31)),
          ),
        },
      ),
      routeEstimator: routeEstimator,
    );

    final result = await service.buildForRide(ride: buildRide(), now: now);

    expect(result, isEmpty);
    expect(routeEstimator.calls, 0);
  });

  test('skips unavailable driver before loading location', () async {
    final locationRepository = _FakeDriverLiveLocationRepository(
      locations: {
        'driver-001': DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.6977,
          longitude: 23.3219,
          updatedAt: now,
        ),
      },
    );

    final routeEstimator = _FakeRouteEstimator(
      result: RouteEstimate(distanceMeters: 1000, durationSeconds: 200),
    );

    final service = DispatchCandidateService(
      shiftRepository: _FakeDriverShiftRepository(
        shifts: [buildShift(availability: DriverQueueAvailability.busy)],
      ),
      liveLocationRepository: locationRepository,
      routeEstimator: routeEstimator,
    );

    final result = await service.buildForRide(ride: buildRide(), now: now);

    expect(result, isEmpty);
    expect(locationRepository.findCalls, 0);
    expect(routeEstimator.calls, 0);
  });
}

class _FakeDriverShiftRepository implements DriverShiftRepository {
  _FakeDriverShiftRepository({this.shifts = const []});

  final List<ActiveDriverShift> shifts;

  @override
  Future<List<ActiveDriverShift>> findAllActive() async {
    return shifts;
  }

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async {
    return null;
  }

  @override
  Future<ActiveDriverShift> startShift({
    required String shiftId,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> endShift({required String shiftId, required DateTime endedAt}) {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeDriverLiveLocationRepository
    implements DriverLiveLocationRepository {
  _FakeDriverLiveLocationRepository({this.locations = const {}});

  final Map<String, DriverLiveLocation> locations;

  int findCalls = 0;

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async {
    findCalls += 1;
    return locations[driverId];
  }

  @override
  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeRouteEstimator implements RouteEstimator {
  _FakeRouteEstimator({required this.result});

  final RouteEstimate result;

  int calls = 0;
  RouteWaypoint? lastOrigin;
  RouteWaypoint? lastDestination;

  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    calls += 1;
    lastOrigin = origin;
    lastDestination = destination;

    return result;
  }
}

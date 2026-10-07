import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

void main() {
  test('creates pending offer for selected available driver', () async {
    final now = DateTime.utc(2026, 10, 7, 20);

    final queueState = DriverQueueState.restore(
      driverId: 'driver-001',
      queuePrioritySince: now.subtract(const Duration(minutes: 10)),
      availability: DriverQueueAvailability.available,
      shortBreaksUsed: 0,
      breakStartedAt: null,
      hasPendingOffer: false,
    );

    final shift = ActiveDriverShift.restore(
      id: 'shift-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      startedAt: now.subtract(const Duration(hours: 1)),
      queueState: queueState,
    );

    final candidateService = DispatchCandidateService(
      shiftRepository: _FakeDriverShiftRepository([shift]),
      liveLocationRepository: _FakeDriverLiveLocationRepository(
        DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.6977,
          longitude: 23.3219,
          updatedAt: now.subtract(const Duration(seconds: 5)),
        ),
      ),
      routeEstimator: _FakeRouteEstimator(),
    );

    final atomicRepository = _FakeAtomicRideOfferRepository();

    final orchestrator = AutomaticDispatchOrchestrator(
      candidateService: candidateService,
      offerRepository: _FakeRideOfferRepository(),
      atomicOfferRepository: atomicRepository,
    );

    final ride = RideRequest(
      id: 'ride-001',
      pickup: 'Sofia Center',
      destination: 'Sofia Airport',
      passengers: 1,
      requestedAt: now,
    );

    final offer = await orchestrator.createNextOffer(
      ride: ride,
      offerId: 'offer-001',
      now: now,
    );

    expect(offer, isNotNull);
    expect(offer!.id, 'offer-001');
    expect(offer.rideId, 'ride-001');
    expect(offer.driverId, 'driver-001');
    expect(offer.vehicleId, 'vehicle-001');
    expect(offer.status, RideOfferStatus.pending);

    expect(atomicRepository.createdOffer?.id, 'offer-001');
  });
  test('returns null when there are no eligible candidates', () async {
    final now = DateTime.utc(2026, 10, 7, 20);

    final candidateService = DispatchCandidateService(
      shiftRepository: _FakeDriverShiftRepository([]),
      liveLocationRepository: _FakeDriverLiveLocationRepository(
        DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.6977,
          longitude: 23.3219,
          updatedAt: now,
        ),
      ),
      routeEstimator: _FakeRouteEstimator(),
    );

    final atomicRepository = _FakeAtomicRideOfferRepository();

    final orchestrator = AutomaticDispatchOrchestrator(
      candidateService: candidateService,
      offerRepository: _FakeRideOfferRepository(),
      atomicOfferRepository: atomicRepository,
    );

    final ride = RideRequest(
      id: 'ride-002',
      pickup: 'Sofia Center',
      destination: 'Sofia Airport',
      passengers: 1,
      requestedAt: now,
    );

    final offer = await orchestrator.createNextOffer(
      ride: ride,
      offerId: 'offer-002',
      now: now,
    );

    expect(offer, isNull);
    expect(atomicRepository.createdOffer, isNull);
  });
}

class _FakeDriverShiftRepository implements DriverShiftRepository {
  _FakeDriverShiftRepository(this.shifts);

  final List<ActiveDriverShift> shifts;

  @override
  Future<List<ActiveDriverShift>> findAllActive() async => shifts;

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async =>
      null;

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
  _FakeDriverLiveLocationRepository(this.location);

  final DriverLiveLocation location;

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async {
    return driverId == location.driverId ? location : null;
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
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    return RouteEstimate(distanceMeters: 1200, durationSeconds: 240);
  }
}

class _FakeRideOfferRepository implements RideOfferRepository {
  @override
  Future<List<RideOffer>> findByRideId(String rideId) async => [];

  @override
  Future<RideOffer?> findById(String id) async => null;

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async => [];

  @override
  Future<void> create(RideOffer offer) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<bool> resolve(RideOffer offer) {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeAtomicRideOfferRepository implements AtomicRideOfferRepository {
  RideOffer? createdOffer;

  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) async {
    createdOffer = offer;
    return offer;
  }

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> movePendingRideToWaitingForVehicle({required String rideId}) {
    throw UnsupportedError('Not needed by this test.');
  }
}

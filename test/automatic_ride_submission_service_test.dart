import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_bonus_decision_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_exhaustion_service.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/automatic_ride_submission_service.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:gocity6_backend/ride/ride_lifecycle_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

void main() {
  test('moves ride to waiting when no dispatch candidate exists', () async {
    final now = DateTime.utc(2026, 10, 7, 20);

    final rideRepository = _FakeRideRequestRepository();

    final candidateService = DispatchCandidateService(
      shiftRepository: _FakeDriverShiftRepository(),
      liveLocationRepository: _FakeDriverLiveLocationRepository(),
      routeEstimator: _FakeRouteEstimator(),
    );

    final orchestrator = AutomaticDispatchOrchestrator(
      candidateService: candidateService,
      offerRepository: _FakeRideOfferRepository(),
      atomicOfferRepository: _FakeAtomicRideOfferRepository(),
    );

    final bonusRepository = _FakeBonusDecisionRepository(rideRepository);

    final service = AutomaticRideSubmissionService(
      lifecycleService: RideLifecycleService(repository: rideRepository),
      rideRepository: rideRepository,
      dispatchOrchestrator: orchestrator,
      exhaustionService: AutomaticDispatchExhaustionService(
        bonusDecisionRepository: bonusRepository,
      ),
      offerIdFactory: () => 'offer-001',
      now: () => now,
    );

    final result = await service.submit(
      RideRequest(
        id: 'ride-001',
        pickup: 'Sofia Center',
        destination: 'Sofia Airport',
        passengers: 1,
        requestedAt: now,
      ),
    );

    expect(result.offer, isNull);
    expect(result.ride.status, RideRequestStatus.waitingForVehicle);

    final storedRide = await rideRepository.findById('ride-001');

    expect(storedRide?.status, RideRequestStatus.waitingForVehicle);
  });
  test('creates offer and keeps ride pending when candidate exists', () async {
    final now = DateTime.utc(2026, 10, 7, 20);

    final rideRepository = _FakeRideRequestRepository();

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
      shiftRepository: _FakeDriverShiftRepositoryWithShift(shift),
      liveLocationRepository: _FakeDriverLiveLocationRepositoryWithLocation(
        DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.6977,
          longitude: 23.3219,
          updatedAt: now.subtract(const Duration(seconds: 5)),
        ),
      ),
      routeEstimator: _FakeRouteEstimatorWithResult(),
    );

    final atomicOfferRepository = _FakeAtomicRideOfferRepositoryWithCreate();

    final orchestrator = AutomaticDispatchOrchestrator(
      candidateService: candidateService,
      offerRepository: _FakeRideOfferRepository(),
      atomicOfferRepository: atomicOfferRepository,
    );

    final bonusRepository = _FakeBonusDecisionRepository(rideRepository);

    final service = AutomaticRideSubmissionService(
      lifecycleService: RideLifecycleService(repository: rideRepository),
      rideRepository: rideRepository,
      dispatchOrchestrator: orchestrator,
      exhaustionService: AutomaticDispatchExhaustionService(
        bonusDecisionRepository: bonusRepository,
      ),
      offerIdFactory: () => 'offer-002',
      now: () => now,
    );

    final result = await service.submit(
      RideRequest(
        id: 'ride-002',
        pickup: 'Sofia Center',
        destination: 'Sofia Airport',
        passengers: 1,
        requestedAt: now,
      ),
    );

    expect(result.offer, isNotNull);
    expect(result.offer?.id, 'offer-002');
    expect(result.offer?.driverId, 'driver-001');
    expect(result.ride.status, RideRequestStatus.pending);

    final storedRide = await rideRepository.findById('ride-002');

    expect(storedRide?.status, RideRequestStatus.pending);
    expect(atomicOfferRepository.createdOffer?.id, 'offer-002');
  });
}

class _FakeRideRequestRepository implements RideRequestRepository {
  final Map<String, RideRequest> rides = {};

  @override
  Future<RideRequest?> findById(String id) async {
    return rides[id];
  }

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {
    return [];
  }

  @override
  Future<void> save(RideRequest request) async {
    rides[request.id] = request;
  }
}

class _FakeDriverShiftRepository implements DriverShiftRepository {
  @override
  Future<List<ActiveDriverShift>> findAllActive() async => [];

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
  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async {
    return null;
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
  }) {
    throw UnsupportedError('No route should be requested.');
  }
}

class _FakeRideOfferRepository implements RideOfferRepository {
  @override
  Future<List<RideOffer>> findByRideId(String rideId) async => [];

  @override
  Future<RideOffer?> findById(String id) async => null;

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async {
    return [];
  }

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
  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) {
    throw UnsupportedError('No offer should be created.');
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

class _FakeBonusDecisionRepository
    implements AtomicRideBonusDecisionRepository {
  _FakeBonusDecisionRepository(this.rideRepository);

  final _FakeRideRequestRepository rideRepository;

  @override
  Future<void> moveRoundOneWithoutOffersToWaitingForVehicle({
    required String rideId,
  }) async {
    final ride = await rideRepository.findById(rideId);

    if (ride == null) {
      throw StateError('Ride not found.');
    }

    await rideRepository.save(
      ride.transitionTo(RideRequestStatus.waitingForVehicle),
    );
  }

  @override
  Future<void> markAwaitingCustomer({required String rideId}) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> acceptFiveEuroBonus({required String rideId}) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> declineBonusAndMoveToWaitingForVehicle({
    required String rideId,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> moveRoundTwoBonusToWaitingForVehicle({required String rideId}) {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeDriverShiftRepositoryWithShift implements DriverShiftRepository {
  _FakeDriverShiftRepositoryWithShift(this.shift);

  final ActiveDriverShift shift;

  @override
  Future<List<ActiveDriverShift>> findAllActive() async {
    return [shift];
  }

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async {
    return driverId == shift.driverId ? shift : null;
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

class _FakeDriverLiveLocationRepositoryWithLocation
    implements DriverLiveLocationRepository {
  _FakeDriverLiveLocationRepositoryWithLocation(this.location);

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

class _FakeRouteEstimatorWithResult implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    return RouteEstimate(distanceMeters: 1200, durationSeconds: 240);
  }
}

class _FakeAtomicRideOfferRepositoryWithCreate
    implements AtomicRideOfferRepository {
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

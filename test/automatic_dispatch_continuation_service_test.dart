import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_bonus_decision_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_continuation_service.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_exhaustion_service.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_repository.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

void main() {
  test('creates next offer for different driver after expired offer', () async {
    final now = DateTime.utc(2026, 10, 9, 10);

    final ride = RideRequest(
      id: 'ride-001',
      pickup: 'Sofia Center',
      destination: 'Sofia Airport',
      passengers: 1,
      requestedAt: now.subtract(const Duration(minutes: 1)),
    );

    final expiredOffer = RideOffer.create(
      id: 'offer-old',
      rideId: ride.id,
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 100,
      distanceMeters: 500,
      offeredAt: now.subtract(const Duration(seconds: 30)),
      timeout: const Duration(seconds: 15),
    ).expire(now.subtract(const Duration(seconds: 10)));

    final firstState = DriverQueueState.restore(
      driverId: 'driver-001',
      queuePrioritySince: now.subtract(const Duration(minutes: 20)),
      availability: DriverQueueAvailability.available,
      shortBreaksUsed: 0,
      breakStartedAt: null,
      hasPendingOffer: false,
    );

    final secondState = DriverQueueState.restore(
      driverId: 'driver-002',
      queuePrioritySince: now.subtract(const Duration(minutes: 10)),
      availability: DriverQueueAvailability.available,
      shortBreaksUsed: 0,
      breakStartedAt: null,
      hasPendingOffer: false,
    );

    final shifts = [
      ActiveDriverShift.restore(
        id: 'shift-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        startedAt: now.subtract(const Duration(hours: 1)),
        queueState: firstState,
      ),
      ActiveDriverShift.restore(
        id: 'shift-002',
        driverId: 'driver-002',
        vehicleId: 'vehicle-002',
        startedAt: now.subtract(const Duration(hours: 1)),
        queueState: secondState,
      ),
    ];

    final offerRepository = _FakeRideOfferRepository(offers: [expiredOffer]);

    final atomicOfferRepository = _FakeAtomicRideOfferRepository();

    final candidateService = DispatchCandidateService(
      shiftRepository: _FakeDriverShiftRepository(shifts),
      liveLocationRepository: _FakeDriverLiveLocationRepository({
        'driver-001': DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.6977,
          longitude: 23.3219,
          updatedAt: now.subtract(const Duration(seconds: 5)),
        ),
        'driver-002': DriverLiveLocation(
          driverId: 'driver-002',
          latitude: 42.6980,
          longitude: 23.3220,
          updatedAt: now.subtract(const Duration(seconds: 5)),
        ),
      }),
      routeEstimator: _FakeRouteEstimator(),
    );

    final orchestrator = AutomaticDispatchOrchestrator(
      candidateService: candidateService,
      offerRepository: offerRepository,
      atomicOfferRepository: atomicOfferRepository,
    );

    final service = AutomaticDispatchContinuationService(
      rideRepository: _FakeRideRequestRepository(ride),
      offerRepository: offerRepository,
      dispatchOrchestrator: orchestrator,
      exhaustionService: AutomaticDispatchExhaustionService(
        bonusDecisionRepository: _FakeBonusDecisionRepository(),
      ),
      offerIdFactory: () => 'offer-new',
      now: () => now,
    );

    final result = await service.continueRide(rideId: ride.id);

    expect(result, isNotNull);
    expect(result?.id, 'offer-new');
    expect(result?.driverId, 'driver-002');

    expect(atomicOfferRepository.createdOffer?.driverId, 'driver-002');
  });
}

class _FakeRideRequestRepository implements RideRequestRepository {
  _FakeRideRequestRepository(this.ride);

  final RideRequest ride;

  @override
  Future<RideRequest?> findById(String id) async {
    return id == ride.id ? ride : null;
  }

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {
    return [];
  }

  @override
  Future<void> save(RideRequest request) {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeRideOfferRepository implements RideOfferRepository {
  _FakeRideOfferRepository({required this.offers});

  final List<RideOffer> offers;

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async {
    return offers.where((offer) => offer.rideId == rideId).toList();
  }

  @override
  Future<RideOffer?> findById(String id) async {
    return null;
  }

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

class _FakeDriverShiftRepository implements DriverShiftRepository {
  _FakeDriverShiftRepository(this.shifts);

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
  _FakeDriverLiveLocationRepository(this.locations);

  final Map<String, DriverLiveLocation> locations;

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async {
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
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    return RouteEstimate(distanceMeters: 700, durationSeconds: 120);
  }
}

class _FakeBonusDecisionRepository
    implements AtomicRideBonusDecisionRepository {
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
  Future<void> moveRoundOneWithoutOffersToWaitingForVehicle({
    required String rideId,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> moveRoundTwoBonusToWaitingForVehicle({required String rideId}) {
    throw UnsupportedError('Not needed by this test.');
  }
}

import 'dart:async';

import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_redispatch_service.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/idempotent_automatic_redispatch_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_repository.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 25, 12);

  test(
    'first attempt creates an automatic offer linked to the action',
    () async {
      final rig = _Rig(rideId: 'ride-first', now: now);

      final result = await rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-first',
        leaseToken: 'lease-first',
      );

      expect(result, isA<AutomaticDispatchRedispatchCreated>());
      final created = (result as AutomaticDispatchRedispatchCreated).offer;
      expect(created.source, RideOfferSource.automatic);
      expect(created.dispatchRound, RideOffer.normalDispatchRound);
      expect(rig.actionRepository.offerFor('action-first')?.id, created.id);
      expect(rig.actionRepository.persistedCreateCount, 1);
    },
  );

  test(
    'same action returns already progressed without more dispatch work',
    () async {
      final rig = _Rig(rideId: 'ride-retry', now: now);
      final first = await rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-retry',
        leaseToken: 'lease-retry',
      );
      final originalOffer = (first as AutomaticDispatchRedispatchCreated).offer;
      final routeCalls = rig.routeEstimator.calls;
      final generatedIds = rig.generatedOfferIds;

      final retry = await rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-retry',
        leaseToken: 'replacement-lease',
      );

      expect(retry, isA<AutomaticDispatchRedispatchAlreadyProgressed>());
      expect(
        (retry as AutomaticDispatchRedispatchAlreadyProgressed).offer.id,
        originalOffer.id,
      );
      expect(rig.actionRepository.persistedCreateCount, 1);
      expect(rig.routeEstimator.calls, routeCalls);
      expect(rig.generatedOfferIds, generatedIds);
    },
  );

  test(
    'same action remains progressed after its first offer expires',
    () async {
      final rig = _Rig(rideId: 'ride-expired', now: now);
      final expired = RideOffer.create(
        id: 'offer-expired',
        rideId: rig.ride.id,
        driverId: 'driver-expired',
        vehicleId: 'vehicle-expired',
        etaSeconds: 90,
        distanceMeters: 400,
        offeredAt: now.subtract(const Duration(seconds: 30)),
        timeout: const Duration(seconds: 15),
      ).expire(now);
      rig.actionRepository.seed('action-expired', expired);
      rig.offerRepository.offers.add(expired);

      final retry = await rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-expired',
        leaseToken: 'new-lease',
      );

      expect(retry, isA<AutomaticDispatchRedispatchAlreadyProgressed>());
      expect(
        (retry as AutomaticDispatchRedispatchAlreadyProgressed).offer.status,
        RideOfferStatus.expired,
      );
      expect(rig.actionRepository.persistedCreateCount, 0);
      expect(rig.routeEstimator.calls, 0);
      expect(rig.generatedOfferIds, 0);
    },
  );

  test('different action id can create a later offer for the ride', () async {
    final rig = _Rig(rideId: 'ride-different-action', now: now);
    final expired = RideOffer.create(
      id: 'offer-from-prior-action',
      rideId: rig.ride.id,
      driverId: 'driver-previous',
      vehicleId: 'vehicle-previous',
      etaSeconds: 90,
      distanceMeters: 400,
      offeredAt: now.subtract(const Duration(seconds: 30)),
      timeout: const Duration(seconds: 15),
    ).expire(now);
    rig.actionRepository.seed('action-prior', expired);
    rig.offerRepository.offers.add(expired);

    final result = await rig.service.redispatch(
      rideId: rig.ride.id,
      actionId: 'action-next',
      leaseToken: 'lease-next',
    );

    expect(result, isA<AutomaticDispatchRedispatchCreated>());
    final created = (result as AutomaticDispatchRedispatchCreated).offer;
    expect(created.id, isNot(expired.id));
    expect(rig.actionRepository.offerFor('action-next')?.id, created.id);
    expect(rig.actionRepository.persistedCreateCount, 1);
  });

  test('concurrent attempts create only one offer for the action', () async {
    final rig = _Rig(rideId: 'ride-concurrent', now: now);
    rig.actionRepository.requireTwoLookupsBeforeProceeding();

    final results = await Future.wait([
      rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-concurrent',
        leaseToken: 'lease-a',
      ),
      rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-concurrent',
        leaseToken: 'lease-b',
      ),
    ]);

    expect(
      results.whereType<AutomaticDispatchRedispatchCreated>(),
      hasLength(1),
    );
    expect(
      results.whereType<AutomaticDispatchRedispatchAlreadyProgressed>(),
      hasLength(1),
    );
    expect(rig.actionRepository.persistedCreateCount, 1);
    expect(rig.actionRepository.offerFor('action-concurrent'), isNotNull);
  });

  test('failure before commit leaves the action retryable', () async {
    final rig = _Rig(rideId: 'ride-before-commit', now: now)
      ..actionRepository.failBeforeCommit = true;

    await expectLater(
      rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-before-commit',
        leaseToken: 'lease-before-commit',
      ),
      throwsA(isA<StateError>()),
    );
    expect(rig.actionRepository.offerFor('action-before-commit'), isNull);
    expect(rig.actionRepository.persistedCreateCount, 0);

    rig.actionRepository.failBeforeCommit = false;
    final retry = await rig.service.redispatch(
      rideId: rig.ride.id,
      actionId: 'action-before-commit',
      leaseToken: 'lease-before-commit-retry',
    );

    expect(retry, isA<AutomaticDispatchRedispatchCreated>());
    expect(rig.actionRepository.persistedCreateCount, 1);
  });

  test(
    'committed offer is recovered after the worker loses its result',
    () async {
      final rig = _Rig(rideId: 'ride-after-commit', now: now)
        ..actionRepository.failAfterCommit = true;

      await expectLater(
        rig.service.redispatch(
          rideId: rig.ride.id,
          actionId: 'action-after-commit',
          leaseToken: 'lease-after-commit',
        ),
        throwsA(isA<StateError>()),
      );
      final committed = rig.actionRepository.offerFor('action-after-commit');
      expect(committed, isNotNull);
      expect(rig.actionRepository.persistedCreateCount, 1);

      rig.actionRepository.failAfterCommit = false;
      final retry = await rig.service.redispatch(
        rideId: rig.ride.id,
        actionId: 'action-after-commit',
        leaseToken: 'new-lease-after-recovery',
      );

      expect(retry, isA<AutomaticDispatchRedispatchAlreadyProgressed>());
      expect(
        (retry as AutomaticDispatchRedispatchAlreadyProgressed).offer.id,
        committed!.id,
      );
      expect(rig.actionRepository.persistedCreateCount, 1);
    },
  );
}

final class _Rig {
  _Rig({required String rideId, required this.now})
    : ride = RideRequest(
        id: rideId,
        pickup: 'Pickup',
        destination: 'Destination',
        passengers: 1,
        requestedAt: now.subtract(const Duration(minutes: 1)),
      ) {
    final state = DriverQueueState.restore(
      driverId: 'driver-$rideId',
      queuePrioritySince: now.subtract(const Duration(minutes: 5)),
      availability: DriverQueueAvailability.available,
      shortBreaksUsed: 0,
      breakStartedAt: null,
      hasPendingOffer: false,
    );
    final shift = ActiveDriverShift.restore(
      id: 'shift-$rideId',
      driverId: state.driverId,
      vehicleId: 'vehicle-$rideId',
      startedAt: now.subtract(const Duration(hours: 1)),
      queueState: state,
    );
    routeEstimator = _FakeRouteEstimator();
    offerRepository = _FakeRideOfferRepository();
    actionRepository = _MemoryRedispatchOfferRepository();
    final orchestrator = AutomaticDispatchOrchestrator(
      candidateService: DispatchCandidateService(
        shiftRepository: _FakeDriverShiftRepository([shift]),
        liveLocationRepository: _FakeDriverLiveLocationRepository({
          state.driverId: DriverLiveLocation(
            driverId: state.driverId,
            latitude: 42.6977,
            longitude: 23.3219,
            updatedAt: now.subtract(const Duration(seconds: 5)),
          ),
        }),
        routeEstimator: routeEstimator,
      ),
      offerRepository: offerRepository,
      atomicOfferRepository: _UnusedAtomicOfferRepository(),
    );
    service = AutomaticDispatchRedispatchService(
      rideRepository: _FakeRideRequestRepository(ride),
      dispatchOrchestrator: orchestrator,
      redispatchOfferRepository: actionRepository,
      offerIdFactory: () => 'offer-${++generatedOfferIds}',
      now: () => now,
    );
  }

  final DateTime now;
  final RideRequest ride;
  late final _FakeRideOfferRepository offerRepository;
  late final _MemoryRedispatchOfferRepository actionRepository;
  late final _FakeRouteEstimator routeEstimator;
  late final AutomaticDispatchRedispatchService service;
  int generatedOfferIds = 0;
}

final class _MemoryRedispatchOfferRepository
    implements IdempotentAutomaticRedispatchOfferRepository {
  final Map<String, RideOffer> _offersByAction = {};
  Completer<void>? _lookupBarrier;
  int _waitingLookups = 0;
  int persistedCreateCount = 0;
  bool failBeforeCommit = false;
  bool failAfterCommit = false;

  RideOffer? offerFor(String actionId) => _offersByAction[actionId];

  void seed(String actionId, RideOffer offer) {
    _offersByAction[actionId] = offer;
  }

  void requireTwoLookupsBeforeProceeding() {
    _lookupBarrier = Completer<void>();
  }

  @override
  Future<RideOffer?> findOfferByRedispatchActionId(String actionId) async {
    final existing = _offersByAction[actionId];
    final barrier = _lookupBarrier;
    if (existing == null && barrier != null) {
      _waitingLookups++;
      if (_waitingLookups == 2) barrier.complete();
      await barrier.future;
    }
    return existing;
  }

  @override
  Future<IdempotentAutomaticRedispatchPersistenceResult>
  createPendingOfferForRedispatch({
    required RideOffer offer,
    required String actionId,
    required String leaseToken,
  }) async {
    if (actionId.isEmpty || leaseToken.isEmpty) {
      throw ArgumentError('Action and lease identities are required.');
    }
    final existing = _offersByAction[actionId];
    if (existing != null) {
      if (existing.rideId != offer.rideId) {
        throw const AutomaticRedispatchConflictException(
          AutomaticRedispatchConflict.rideMismatch,
        );
      }
      return AutomaticRedispatchAlreadyProgressed(existing);
    }
    if (failBeforeCommit) throw StateError('Simulated pre-commit failure.');

    _offersByAction[actionId] = offer;
    persistedCreateCount++;
    if (failAfterCommit) throw StateError('Simulated lost commit response.');
    return AutomaticRedispatchOfferCreated(offer);
  }
}

final class _FakeRideRequestRepository implements RideRequestRepository {
  const _FakeRideRequestRepository(this.ride);

  final RideRequest ride;

  @override
  Future<RideRequest?> findById(String id) async => id == ride.id ? ride : null;

  @override
  Future<RideRequest?> findByClientRequestId(String clientRequestId) async =>
      ride.clientRequestId == clientRequestId ? ride : null;

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async => [];

  @override
  Future<List<RideRequest>> findWaitingForVehicle() async => [];

  @override
  Future<void> save(RideRequest request) =>
      throw UnsupportedError('Not used by this test.');
}

final class _FakeRideOfferRepository implements RideOfferRepository {
  final List<RideOffer> offers = [];

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async =>
      offers.where((offer) => offer.rideId == rideId).toList();

  @override
  Future<RideOffer?> findById(String id) async => null;

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async => [];

  @override
  Future<void> create(RideOffer offer) =>
      throw UnsupportedError('Not used by this test.');

  @override
  Future<bool> markDisplayed({
    required String offerId,
    required String driverId,
    required DateTime displayedAt,
  }) => throw UnsupportedError('Not used by this test.');

  @override
  Future<bool> resolve(RideOffer offer) =>
      throw UnsupportedError('Not used by this test.');
}

final class _UnusedAtomicOfferRepository implements AtomicRideOfferRepository {
  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) =>
      throw UnsupportedError('Redispatch uses its idempotent repository.');

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnsupportedError('Not used by this test.');

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnsupportedError('Not used by this test.');

  @override
  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnsupportedError('Not used by this test.');

  @override
  Future<void> movePendingRideToWaitingForVehicle({required String rideId}) =>
      throw UnsupportedError('Not used by this test.');
}

final class _FakeDriverShiftRepository implements DriverShiftRepository {
  const _FakeDriverShiftRepository(this.shifts);

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
  }) => throw UnsupportedError('Not used by this test.');

  @override
  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  }) => throw UnsupportedError('Not used by this test.');

  @override
  Future<void> endShift({required String shiftId, required DateTime endedAt}) =>
      throw UnsupportedError('Not used by this test.');
}

final class _FakeDriverLiveLocationRepository
    implements DriverLiveLocationRepository {
  const _FakeDriverLiveLocationRepository(this.locations);

  final Map<String, DriverLiveLocation> locations;

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async =>
      locations[driverId];

  @override
  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  }) => throw UnsupportedError('Not used by this test.');
}

final class _FakeRouteEstimator implements RouteEstimator {
  int calls = 0;

  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    calls++;
    return RouteEstimate(distanceMeters: 600, durationSeconds: 100);
  }
}

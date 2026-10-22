import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/driver_ride_offer_action_service.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:test/test.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_policy_service.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/ride/in_memory_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';

void main() {
  final now = DateTime.utc(2026, 10, 6, 20);
  DriverDispatchPolicyService buildDispatchPolicyService(
    _FakeDriverDispatchStateRepository repository,
  ) {
    return DriverDispatchPolicyService(repository: repository);
  }

  RideOffer buildOffer({
    String driverId = 'driver-001',
    int dispatchRound = RideOffer.normalDispatchRound,
    int bonusMinor = RideOffer.noBonusMinor,
  }) {
    return RideOffer.create(
      id: 'offer-001',
      rideId: 'ride-001',
      driverId: driverId,
      vehicleId: 'vehicle-001',
      etaSeconds: 120,
      distanceMeters: 900,
      offeredAt: now.subtract(const Duration(seconds: 5)),
      timeout: const Duration(seconds: 15),
      dispatchRound: dispatchRound,
      bonusMinor: bonusMinor,
    );
  }

  RideRequest buildRide(
    RideOffer offer, {
    Duration requestAgeAtOffer = const Duration(minutes: 1),
  }) {
    final isBonus = offer.dispatchRound == RideOffer.bonusDispatchRound;

    return RideRequest(
      id: offer.rideId,
      pickup: 'Pickup',
      destination: 'Destination',
      passengers: 1,
      requestedAt: offer.offeredAt.subtract(requestAgeAtOffer),
      dispatchRound: offer.dispatchRound,
      driverBonusMinor: isBonus
          ? RideRequest.driverBonusFiveEuroMinor
          : RideRequest.noDriverBonusMinor,
      bonusDecision: isBonus
          ? RideBonusDecision.accepted
          : RideBonusDecision.notOffered,
    );
  }

  test('accepts offer owned by authenticated driver', () async {
    final offer = buildOffer();

    final atomicRepository = _FakeAtomicRideOfferRepository(offer: offer);
    final dispatchStateRepository = _FakeDriverDispatchStateRepository(
      initialState: const DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 0,
        penaltyLevel: 1,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
        requiresCompletedRideAfterPenalty: true,
      ),
    );

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(offer: offer),
      atomicOfferRepository: atomicRepository,
      rideRepository: InMemoryRideRequestRepository([buildRide(offer)]),
      dispatchPolicyService: buildDispatchPolicyService(
        dispatchStateRepository,
      ),
      continueRide: ({required String rideId}) async => null,
    );

    final result = await service.accept(
      driverId: 'driver-001',
      offerId: 'offer-001',
      now: now,
    );

    expect(result.status, RideOfferStatus.accepted);
    expect(atomicRepository.acceptCalls, 1);
    expect(atomicRepository.lastOfferId, 'offer-001');
    expect(dispatchStateRepository.updateCalls, 0);
    expect(
      dispatchStateRepository.state?.requiresCompletedRideAfterPenalty,
      isTrue,
    );
  });

  test('rejects offer and continues automatic dispatch', () async {
    final offer = buildOffer();

    final atomicRepository = _FakeAtomicRideOfferRepository(offer: offer);

    String? continuedRideId;

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(offer: offer),
      atomicOfferRepository: atomicRepository,
      rideRepository: InMemoryRideRequestRepository([buildRide(offer)]),
      dispatchPolicyService: buildDispatchPolicyService(
        _FakeDriverDispatchStateRepository(),
      ),
      continueRide: ({required String rideId}) async {
        continuedRideId = rideId;
        return null;
      },
    );

    final result = await service.reject(
      driverId: 'driver-001',
      offerId: 'offer-001',
      now: now,
    );

    expect(result.status, RideOfferStatus.rejected);
    expect(atomicRepository.rejectCalls, 1);
    expect(atomicRepository.lastOfferId, 'offer-001');
    expect(continuedRideId, 'ride-001');
  });
  test('records normal rejected offer in dispatch policy', () async {
    final offer = buildOffer();
    final atomicRepository = _FakeAtomicRideOfferRepository(offer: offer);
    final dispatchStateRepository = _FakeDriverDispatchStateRepository();

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(offer: offer),
      atomicOfferRepository: atomicRepository,
      rideRepository: InMemoryRideRequestRepository([buildRide(offer)]),
      dispatchPolicyService: buildDispatchPolicyService(
        dispatchStateRepository,
      ),
      continueRide: ({required String rideId}) async => null,
    );

    await service.reject(
      driverId: 'driver-001',
      offerId: 'offer-001',
      now: now,
    );

    expect(dispatchStateRepository.state?.consecutiveRejects, 1);
    expect(dispatchStateRepository.state?.penaltyLevel, 0);
    expect(dispatchStateRepository.state?.dispatchBlockedUntil, isNull);
  });

  test(
    'standard rejection after an expired sanction immediately escalates',
    () async {
      final offer = buildOffer();
      final stateRepository = _FakeDriverDispatchStateRepository(
        initialState: DriverDispatchState(
          driverId: 'driver-001',
          consecutiveRejects: 0,
          penaltyLevel: 1,
          dispatchBlockedUntil: now.subtract(const Duration(seconds: 1)),
          penaltyResetEligibleAt: null,
          requiresCompletedRideAfterPenalty: true,
        ),
      );
      final service = DriverRideOfferActionService(
        offerRepository: _FakeRideOfferRepository(offer: offer),
        atomicOfferRepository: _FakeAtomicRideOfferRepository(offer: offer),
        rideRepository: InMemoryRideRequestRepository([buildRide(offer)]),
        dispatchPolicyService: buildDispatchPolicyService(stateRepository),
        continueRide: ({required String rideId}) async => null,
      );

      await service.reject(driverId: 'driver-001', offerId: offer.id, now: now);

      expect(stateRepository.state?.consecutiveRejects, 0);
      expect(stateRepository.state?.penaltyLevel, 2);
      expect(
        stateRepository.state?.dispatchBlockedUntil,
        now.add(const Duration(minutes: 60)),
      );
      expect(stateRepository.state?.requiresCompletedRideAfterPenalty, isTrue);
    },
  );
  test(
    'records bonus rejected offer with immediate 30 minute cooldown',
    () async {
      const age = Duration(minutes: 19, seconds: 59);
      final offer = buildOffer(
        dispatchRound: RideOffer.bonusDispatchRound,
        bonusMinor: RideOffer.shortRideBonusMinor,
      );
      final atomicRepository = _FakeAtomicRideOfferRepository(offer: offer);
      final dispatchStateRepository = _FakeDriverDispatchStateRepository();

      final service = DriverRideOfferActionService(
        offerRepository: _FakeRideOfferRepository(offer: offer),
        atomicOfferRepository: atomicRepository,
        rideRepository: InMemoryRideRequestRepository([
          buildRide(offer, requestAgeAtOffer: age),
        ]),
        dispatchPolicyService: buildDispatchPolicyService(
          dispatchStateRepository,
        ),
        continueRide: ({required String rideId}) async => null,
      );

      await service.reject(
        driverId: 'driver-001',
        offerId: 'offer-001',
        now: now,
      );

      expect(dispatchStateRepository.state?.consecutiveRejects, 0);
      expect(dispatchStateRepository.state?.penaltyLevel, 0);
      expect(
        dispatchStateRepository.state?.dispatchBlockedUntil,
        now.add(const Duration(minutes: 30)),
      );
    },
  );

  test('penalizes a standard rejection at 19:59', () async {
    const age = Duration(minutes: 19, seconds: 59);
    final offer = buildOffer();
    final stateRepository = _FakeDriverDispatchStateRepository(
      initialState: const DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 1,
        penaltyLevel: 2,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      ),
    );
    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(offer: offer),
      atomicOfferRepository: _FakeAtomicRideOfferRepository(offer: offer),
      rideRepository: InMemoryRideRequestRepository([
        buildRide(offer, requestAgeAtOffer: age),
      ]),
      dispatchPolicyService: buildDispatchPolicyService(stateRepository),
      continueRide: ({required String rideId}) async => null,
    );

    await service.reject(driverId: 'driver-001', offerId: offer.id, now: now);

    expect(stateRepository.updateCalls, 1);
    expect(stateRepository.state?.consecutiveRejects, 2);
    expect(stateRepository.state?.penaltyLevel, 2);
  });

  test(
    'leaves all penalty state unchanged for a standard rejection at 20:00',
    () async {
      const age = Duration(minutes: 20);
      final offer = buildOffer();
      final blockedUntil = now.add(const Duration(minutes: 7));
      final resetEligibleAt = now.add(const Duration(hours: 4));
      final initialState = DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 2,
        penaltyLevel: 4,
        dispatchBlockedUntil: blockedUntil,
        penaltyResetEligibleAt: resetEligibleAt,
      );
      final stateRepository = _FakeDriverDispatchStateRepository(
        initialState: initialState,
      );
      final service = DriverRideOfferActionService(
        offerRepository: _FakeRideOfferRepository(offer: offer),
        atomicOfferRepository: _FakeAtomicRideOfferRepository(offer: offer),
        rideRepository: InMemoryRideRequestRepository([
          buildRide(offer, requestAgeAtOffer: age),
        ]),
        dispatchPolicyService: buildDispatchPolicyService(stateRepository),
        continueRide: ({required String rideId}) async => null,
      );

      await service.reject(driverId: 'driver-001', offerId: offer.id, now: now);

      expect(stateRepository.updateCalls, 0);
      expect(stateRepository.state?.consecutiveRejects, 2);
      expect(stateRepository.state?.penaltyLevel, 4);
      expect(stateRepository.state?.dispatchBlockedUntil, blockedUntil);
      expect(stateRepository.state?.penaltyResetEligibleAt, resetEligibleAt);
    },
  );

  test(
    'leaves all penalty state unchanged for a bonus rejection at 20:00',
    () async {
      const age = Duration(minutes: 20);
      final offer = buildOffer(
        dispatchRound: RideOffer.bonusDispatchRound,
        bonusMinor: RideOffer.shortRideBonusMinor,
      );
      final blockedUntil = now.add(const Duration(minutes: 7));
      final resetEligibleAt = now.add(const Duration(hours: 4));
      final stateRepository = _FakeDriverDispatchStateRepository(
        initialState: DriverDispatchState(
          driverId: 'driver-001',
          consecutiveRejects: 2,
          penaltyLevel: 4,
          dispatchBlockedUntil: blockedUntil,
          penaltyResetEligibleAt: resetEligibleAt,
        ),
      );
      final service = DriverRideOfferActionService(
        offerRepository: _FakeRideOfferRepository(offer: offer),
        atomicOfferRepository: _FakeAtomicRideOfferRepository(offer: offer),
        rideRepository: InMemoryRideRequestRepository([
          buildRide(offer, requestAgeAtOffer: age),
        ]),
        dispatchPolicyService: buildDispatchPolicyService(stateRepository),
        continueRide: ({required String rideId}) async => null,
      );

      await service.reject(driverId: 'driver-001', offerId: offer.id, now: now);

      expect(stateRepository.updateCalls, 0);
      expect(stateRepository.state?.consecutiveRejects, 2);
      expect(stateRepository.state?.penaltyLevel, 4);
      expect(stateRepository.state?.dispatchBlockedUntil, blockedUntil);
      expect(stateRepository.state?.penaltyResetEligibleAt, resetEligibleAt);
    },
  );

  test('rejects action on offer owned by another driver', () async {
    final offer = buildOffer(driverId: 'driver-other');

    final atomicRepository = _FakeAtomicRideOfferRepository(offer: offer);

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(offer: offer),
      atomicOfferRepository: atomicRepository,
      rideRepository: InMemoryRideRequestRepository([buildRide(offer)]),
      dispatchPolicyService: buildDispatchPolicyService(
        _FakeDriverDispatchStateRepository(),
      ),
      continueRide: ({required String rideId}) async => null,
    );

    expect(
      service.accept(driverId: 'driver-001', offerId: 'offer-001', now: now),
      throwsA(
        isA<DriverRideOfferActionException>().having(
          (error) => error.conflict,
          'conflict',
          DriverRideOfferActionConflict.offerDoesNotBelongToDriver,
        ),
      ),
    );

    expect(atomicRepository.acceptCalls, 0);
  });

  test('rejects action when offer does not exist', () async {
    final atomicRepository = _FakeAtomicRideOfferRepository();

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(),
      atomicOfferRepository: atomicRepository,
      rideRepository: InMemoryRideRequestRepository(),
      dispatchPolicyService: buildDispatchPolicyService(
        _FakeDriverDispatchStateRepository(),
      ),
      continueRide: ({required String rideId}) async => null,
    );

    expect(
      service.reject(
        driverId: 'driver-001',
        offerId: 'missing-offer',
        now: now,
      ),
      throwsA(
        isA<DriverRideOfferActionException>().having(
          (error) => error.conflict,
          'conflict',
          DriverRideOfferActionConflict.offerNotFound,
        ),
      ),
    );

    expect(atomicRepository.rejectCalls, 0);
  });
}

class _FakeRideOfferRepository implements RideOfferRepository {
  _FakeRideOfferRepository({this.offer});

  final RideOffer? offer;

  @override
  Future<RideOffer?> findById(String id) async {
    if (offer?.id == id) {
      return offer;
    }

    return null;
  }

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> create(RideOffer offer) async {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<bool> markDisplayed({
    required String offerId,
    required String driverId,
    required DateTime displayedAt,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<bool> resolve(RideOffer offer) async {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeAtomicRideOfferRepository implements AtomicRideOfferRepository {
  _FakeAtomicRideOfferRepository({this.offer});

  final RideOffer? offer;

  int acceptCalls = 0;
  int rejectCalls = 0;
  String? lastOfferId;

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) async {
    acceptCalls += 1;
    lastOfferId = offerId;

    return offer!.accept(now);
  }

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) async {
    rejectCalls += 1;
    lastOfferId = offerId;

    return offer!.reject(now);
  }

  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) {
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

class _FakeDriverDispatchStateRepository
    implements DriverDispatchStateRepository {
  _FakeDriverDispatchStateRepository({DriverDispatchState? initialState})
    : state = initialState;

  DriverDispatchState? state;
  int updateCalls = 0;

  @override
  Future<DriverDispatchState?> findByDriverId(String driverId) async {
    return state;
  }

  @override
  Future<DriverDispatchState> save(DriverDispatchState state) async {
    this.state = state;
    return state;
  }

  @override
  Future<DriverDispatchState> updateAtomically({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  }) async {
    updateCalls += 1;
    final current =
        state ??
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: 0,
          dispatchBlockedUntil: null,
          penaltyResetEligibleAt: null,
        );

    final next = transform(current);
    state = next;
    return next;
  }
}

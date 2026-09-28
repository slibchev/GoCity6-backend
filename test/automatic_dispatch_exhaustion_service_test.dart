import 'package:gocity6_backend/dispatch/atomic_ride_bonus_decision_repository.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_coordinator.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_exhaustion_service.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_history.dart';
import 'package:test/test.dart';

class _FakeBonusDecisionRepository
    implements AtomicRideBonusDecisionRepository {
  final List<String> calls = [];

  @override
  Future<void> markAwaitingCustomer({required String rideId}) async {
    calls.add('markAwaitingCustomer:$rideId');
  }

  @override
  Future<void> acceptFiveEuroBonus({required String rideId}) async {
    calls.add('acceptFiveEuroBonus:$rideId');
  }

  @override
  Future<void> declineBonusAndMoveToWaitingForVehicle({
    required String rideId,
  }) async {
    calls.add('declineBonusAndMoveToWaitingForVehicle:$rideId');
  }

  @override
  Future<void> moveRoundOneWithoutOffersToWaitingForVehicle({
    required String rideId,
  }) async {
    calls.add('moveRoundOneWithoutOffersToWaitingForVehicle:$rideId');
  }

  @override
  Future<void> moveRoundTwoBonusToWaitingForVehicle({
    required String rideId,
  }) async {
    calls.add('moveRoundTwoBonusToWaitingForVehicle:$rideId');
  }
}

void main() {
  final now = DateTime.utc(2026, 9, 28, 12);

  RideOfferHistory emptyHistory() {
    return RideOfferHistory(rideId: 'ride-001', offers: const []);
  }

  RideOfferHistory rejectedRoundOneHistory() {
    final offer = RideOffer.create(
      id: 'offer-001',
      rideId: 'ride-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 300,
      distanceMeters: 700,
      dispatchRound: RideOffer.normalDispatchRound,
      bonusMinor: RideOffer.noBonusMinor,
      offeredAt: now,
      timeout: const Duration(seconds: 15),
    );

    final rejected = offer.reject(now.add(const Duration(seconds: 5)));

    return RideOfferHistory(rideId: 'ride-001', offers: [rejected]);
  }

  test(
    'exhausted round 1 with offer history marks awaiting customer',
    () async {
      final repository = _FakeBonusDecisionRepository();

      final service = AutomaticDispatchExhaustionService(
        bonusDecisionRepository: repository,
      );

      final action = await service.handleExhaustedRound(
        rideId: 'ride-001',
        dispatchRound: RideOffer.normalDispatchRound,
        history: rejectedRoundOneHistory(),
      );

      expect(
        action,
        AutomaticDispatchExhaustionAction.awaitCustomerBonusDecision,
      );

      expect(repository.calls, ['markAwaitingCustomer:ride-001']);
    },
  );

  test('round 1 with zero offers moves directly to waiting', () async {
    final repository = _FakeBonusDecisionRepository();

    final service = AutomaticDispatchExhaustionService(
      bonusDecisionRepository: repository,
    );

    final action = await service.handleExhaustedRound(
      rideId: 'ride-001',
      dispatchRound: RideOffer.normalDispatchRound,
      history: emptyHistory(),
    );

    expect(
      action,
      AutomaticDispatchExhaustionAction.moveRoundOneToWaitingForVehicle,
    );

    expect(repository.calls, [
      'moveRoundOneWithoutOffersToWaitingForVehicle:ride-001',
    ]);
  });

  test('exhausted round 2 moves bonus ride to waiting', () async {
    final repository = _FakeBonusDecisionRepository();

    final service = AutomaticDispatchExhaustionService(
      bonusDecisionRepository: repository,
    );

    final action = await service.handleExhaustedRound(
      rideId: 'ride-001',
      dispatchRound: RideOffer.bonusDispatchRound,
      history: emptyHistory(),
    );

    expect(
      action,
      AutomaticDispatchExhaustionAction.moveRoundTwoBonusToWaitingForVehicle,
    );

    expect(repository.calls, ['moveRoundTwoBonusToWaitingForVehicle:ride-001']);
  });

  test('history for another ride is rejected before repository call', () async {
    final repository = _FakeBonusDecisionRepository();

    final service = AutomaticDispatchExhaustionService(
      bonusDecisionRepository: repository,
    );

    final wrongHistory = RideOfferHistory(
      rideId: 'ride-other',
      offers: const [],
    );

    expect(
      () => service.handleExhaustedRound(
        rideId: 'ride-001',
        dispatchRound: RideOffer.normalDispatchRound,
        history: wrongHistory,
      ),
      throwsArgumentError,
    );

    expect(repository.calls, isEmpty);
  });
}

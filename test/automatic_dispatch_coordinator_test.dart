import 'package:gocity6_backend/dispatch/automatic_dispatch_coordinator.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_history.dart';
import 'package:test/test.dart';

void main() {
  const coordinator = AutomaticDispatchCoordinator();

  final now = DateTime.utc(2026, 9, 28, 12);

  RideOfferHistory emptyHistory() {
    return RideOfferHistory(rideId: 'ride-001', offers: const []);
  }

  RideOffer rejectedOffer({
    required String id,
    required int dispatchRound,
    required int bonusMinor,
  }) {
    final offer = RideOffer.create(
      id: id,
      rideId: 'ride-001',
      driverId: 'driver-$id',
      vehicleId: 'vehicle-$id',
      etaSeconds: 300,
      distanceMeters: 700,
      dispatchRound: dispatchRound,
      bonusMinor: bonusMinor,
      offeredAt: now,
      timeout: const Duration(seconds: 15),
    );

    return offer.reject(now.add(const Duration(seconds: 5)));
  }

  test('round 1 with no offer history moves directly to waitingForVehicle', () {
    final action = coordinator.resolveExhaustedRound(
      dispatchRound: RideOffer.normalDispatchRound,
      history: emptyHistory(),
    );

    expect(
      action,
      AutomaticDispatchExhaustionAction.moveRoundOneToWaitingForVehicle,
    );
  });

  test(
    'exhausted round 1 after an offer waits for customer bonus decision',
    () {
      final history = RideOfferHistory(
        rideId: 'ride-001',
        offers: [
          rejectedOffer(
            id: 'offer-round-1',
            dispatchRound: RideOffer.normalDispatchRound,
            bonusMinor: RideOffer.noBonusMinor,
          ),
        ],
      );

      final action = coordinator.resolveExhaustedRound(
        dispatchRound: RideOffer.normalDispatchRound,
        history: history,
      );

      expect(
        action,
        AutomaticDispatchExhaustionAction.awaitCustomerBonusDecision,
      );
    },
  );

  test('exhausted round 2 moves bonus ride to waitingForVehicle', () {
    final history = RideOfferHistory(
      rideId: 'ride-001',
      offers: [
        rejectedOffer(
          id: 'offer-round-1',
          dispatchRound: RideOffer.normalDispatchRound,
          bonusMinor: RideOffer.noBonusMinor,
        ),
        rejectedOffer(
          id: 'offer-round-2',
          dispatchRound: RideOffer.bonusDispatchRound,
          bonusMinor: RideOffer.shortRideBonusMinor,
        ),
      ],
    );

    final action = coordinator.resolveExhaustedRound(
      dispatchRound: RideOffer.bonusDispatchRound,
      history: history,
    );

    expect(
      action,
      AutomaticDispatchExhaustionAction.moveRoundTwoBonusToWaitingForVehicle,
    );
  });

  test('pending offer blocks exhausted round resolution', () {
    final pendingOffer = RideOffer.create(
      id: 'offer-pending',
      rideId: 'ride-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 300,
      distanceMeters: 700,
      offeredAt: now,
      timeout: const Duration(seconds: 15),
    );

    final history = RideOfferHistory(
      rideId: 'ride-001',
      offers: [pendingOffer],
    );

    expect(
      () => coordinator.resolveExhaustedRound(
        dispatchRound: RideOffer.normalDispatchRound,
        history: history,
      ),
      throwsA(
        isA<AutomaticDispatchCoordinatorConflictException>().having(
          (error) => error.conflict,
          'conflict',
          AutomaticDispatchCoordinatorConflict.pendingOfferExists,
        ),
      ),
    );
  });

  test('accepted offer blocks exhausted round resolution', () {
    final offer = RideOffer.create(
      id: 'offer-accepted',
      rideId: 'ride-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 300,
      distanceMeters: 700,
      offeredAt: now,
      timeout: const Duration(seconds: 15),
    );

    final acceptedOffer = offer.accept(now.add(const Duration(seconds: 5)));

    final history = RideOfferHistory(
      rideId: 'ride-001',
      offers: [acceptedOffer],
    );

    expect(
      () => coordinator.resolveExhaustedRound(
        dispatchRound: RideOffer.normalDispatchRound,
        history: history,
      ),
      throwsA(
        isA<AutomaticDispatchCoordinatorConflictException>().having(
          (error) => error.conflict,
          'conflict',
          AutomaticDispatchCoordinatorConflict.rideAlreadyAccepted,
        ),
      ),
    );
  });

  test('unsupported dispatch round is rejected', () {
    expect(
      () => coordinator.resolveExhaustedRound(
        dispatchRound: 3,
        history: emptyHistory(),
      ),
      throwsA(
        isA<AutomaticDispatchCoordinatorConflictException>().having(
          (error) => error.conflict,
          'conflict',
          AutomaticDispatchCoordinatorConflict.unsupportedDispatchRound,
        ),
      ),
    );
  });
}

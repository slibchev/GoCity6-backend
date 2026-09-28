import 'atomic_ride_bonus_decision_repository.dart';
import 'automatic_dispatch_coordinator.dart';
import 'ride_offer_history.dart';

class AutomaticDispatchExhaustionService {
  final AutomaticDispatchCoordinator coordinator;
  final AtomicRideBonusDecisionRepository bonusDecisionRepository;

  const AutomaticDispatchExhaustionService({
    this.coordinator = const AutomaticDispatchCoordinator(),
    required this.bonusDecisionRepository,
  });

  Future<AutomaticDispatchExhaustionAction> handleExhaustedRound({
    required String rideId,
    required int dispatchRound,
    required RideOfferHistory history,
  }) async {
    if (history.rideId != rideId) {
      throw ArgumentError('Offer history does not belong to ride $rideId.');
    }

    final action = coordinator.resolveExhaustedRound(
      dispatchRound: dispatchRound,
      history: history,
    );

    switch (action) {
      case AutomaticDispatchExhaustionAction.awaitCustomerBonusDecision:
        await bonusDecisionRepository.markAwaitingCustomer(rideId: rideId);

      case AutomaticDispatchExhaustionAction.moveRoundOneToWaitingForVehicle:
        await bonusDecisionRepository
            .moveRoundOneWithoutOffersToWaitingForVehicle(rideId: rideId);

      case AutomaticDispatchExhaustionAction
          .moveRoundTwoBonusToWaitingForVehicle:
        await bonusDecisionRepository.moveRoundTwoBonusToWaitingForVehicle(
          rideId: rideId,
        );
    }

    return action;
  }
}

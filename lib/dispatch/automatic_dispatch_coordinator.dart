import 'ride_offer.dart';
import 'ride_offer_history.dart';

enum AutomaticDispatchExhaustionAction {
  awaitCustomerBonusDecision,
  moveRoundOneToWaitingForVehicle,
  moveRoundTwoBonusToWaitingForVehicle,
}

enum AutomaticDispatchCoordinatorConflict {
  pendingOfferExists,
  rideAlreadyAccepted,
  unsupportedDispatchRound,
}

class AutomaticDispatchCoordinatorConflictException implements Exception {
  final AutomaticDispatchCoordinatorConflict conflict;

  const AutomaticDispatchCoordinatorConflictException(this.conflict);

  @override
  String toString() {
    return 'Automatic dispatch coordinator conflict: ${conflict.name}';
  }
}

class AutomaticDispatchCoordinator {
  const AutomaticDispatchCoordinator();

  AutomaticDispatchExhaustionAction resolveExhaustedRound({
    required int dispatchRound,
    required RideOfferHistory history,
  }) {
    if (history.hasPendingOffer) {
      throw const AutomaticDispatchCoordinatorConflictException(
        AutomaticDispatchCoordinatorConflict.pendingOfferExists,
      );
    }

    if (history.hasAcceptedOffer) {
      throw const AutomaticDispatchCoordinatorConflictException(
        AutomaticDispatchCoordinatorConflict.rideAlreadyAccepted,
      );
    }

    switch (dispatchRound) {
      case RideOffer.normalDispatchRound:
        if (history.attemptsUsed == 0) {
          return AutomaticDispatchExhaustionAction
              .moveRoundOneToWaitingForVehicle;
        }

        return AutomaticDispatchExhaustionAction.awaitCustomerBonusDecision;

      case RideOffer.bonusDispatchRound:
        return AutomaticDispatchExhaustionAction
            .moveRoundTwoBonusToWaitingForVehicle;

      default:
        throw const AutomaticDispatchCoordinatorConflictException(
          AutomaticDispatchCoordinatorConflict.unsupportedDispatchRound,
        );
    }
  }
}

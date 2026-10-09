import 'atomic_ride_bonus_decision_repository.dart';
import 'ride_offer.dart';

typedef ContinueAutomaticDispatch = Future<RideOffer?> Function({
  required String rideId,
});

class CustomerBonusDecisionService {
  final AtomicRideBonusDecisionRepository bonusDecisionRepository;
  final ContinueAutomaticDispatch continueRide;

  const CustomerBonusDecisionService({
    required this.bonusDecisionRepository,
    required this.continueRide,
  });

  Future<void> accept({required String rideId}) async {
    await bonusDecisionRepository.acceptFiveEuroBonus(rideId: rideId);

    await continueRide(rideId: rideId);
  }

  Future<void> decline({required String rideId}) async {
    await bonusDecisionRepository.declineBonusAndMoveToWaitingForVehicle(
      rideId: rideId,
    );
  }
}

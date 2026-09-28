enum AtomicRideBonusDecisionConflict {
  rideNotFound,
  rideNotPending,
  rideAlreadyAssigned,
  rideHasPendingOffer,
  rideHasNoRoundOneOfferHistory,
  rideHasRoundOneOfferHistory,
  rideDispatchStateMismatch,
}

class AtomicRideBonusDecisionConflictException implements Exception {
  final AtomicRideBonusDecisionConflict conflict;

  const AtomicRideBonusDecisionConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic ride bonus decision conflict: ${conflict.name}';
  }
}

abstract interface class AtomicRideBonusDecisionRepository {
  Future<void> markAwaitingCustomer({required String rideId});

  Future<void> acceptFiveEuroBonus({required String rideId});

  Future<void> declineBonusAndMoveToWaitingForVehicle({required String rideId});

  Future<void> moveRoundOneWithoutOffersToWaitingForVehicle({
    required String rideId,
  });

  Future<void> moveRoundTwoBonusToWaitingForVehicle({required String rideId});
}

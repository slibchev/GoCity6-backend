import 'ride_offer.dart';

enum AtomicRideOfferConflict {
  rideNotFound,
  rideNotPending,
  rideAlreadyAssigned,
  driverShiftNotFound,
  vehicleDoesNotMatchShift,
  driverNotAvailable,
  driverAlreadyHasPendingOffer,
  rideAlreadyHasPendingOffer,
  rideAlreadyOfferedToDriver,
  maxAttemptsReached,
}

class AtomicRideOfferConflictException implements Exception {
  final AtomicRideOfferConflict conflict;

  const AtomicRideOfferConflictException(this.conflict);

  @override
  String toString() {
    return 'Atomic ride offer conflict: ${conflict.name}';
  }
}

abstract interface class AtomicRideOfferRepository {
  Future<RideOffer> createPendingOffer({
    required RideOffer offer,
    required int maxAttempts,
  });
}

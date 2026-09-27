import 'ride_offer.dart';

enum AtomicRideOfferConflict {
  rideNotFound,
  rideNotPending,
  rideAlreadyAssigned,

  offerNotFound,
  offerNotPending,
  offerAlreadyExpired,
  offerNotExpiredYet,

  driverShiftNotFound,
  vehicleDoesNotMatchShift,
  driverNotAvailable,
  driverAlreadyHasPendingOffer,
  driverPendingOfferMissing,

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

  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  });

  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  });

  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  });
}

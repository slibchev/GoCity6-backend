import 'atomic_ride_offer_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_repository.dart';

typedef ContinueAutomaticDispatch = Future<RideOffer?> Function({
  required String rideId,
});

enum DriverRideOfferActionConflict {
  offerNotFound,
  offerDoesNotBelongToDriver,
}

class DriverRideOfferActionException implements Exception {
  final DriverRideOfferActionConflict conflict;

  const DriverRideOfferActionException(this.conflict);

  @override
  String toString() {
    return 'Driver ride offer action conflict: ${conflict.name}';
  }
}

class DriverRideOfferActionService {
  final RideOfferRepository offerRepository;
  final AtomicRideOfferRepository atomicOfferRepository;
  final ContinueAutomaticDispatch continueRide;

  const DriverRideOfferActionService({
    required this.offerRepository,
    required this.atomicOfferRepository,
    required this.continueRide,
  });

  Future<RideOffer> accept({
    required String driverId,
    required String offerId,
    required DateTime now,
  }) async {
    await _requireOwnedOffer(
      driverId: driverId,
      offerId: offerId,
    );

    return atomicOfferRepository.acceptPendingOffer(
      offerId: offerId,
      now: now,
    );
  }

  Future<RideOffer> reject({
    required String driverId,
    required String offerId,
    required DateTime now,
  }) async {
    await _requireOwnedOffer(
      driverId: driverId,
      offerId: offerId,
    );

    final rejectedOffer = await atomicOfferRepository.rejectPendingOffer(
      offerId: offerId,
      now: now,
    );

    await continueRide(
      rideId: rejectedOffer.rideId,
    );

    return rejectedOffer;
  }

  Future<void> _requireOwnedOffer({
    required String driverId,
    required String offerId,
  }) async {
    final offer = await offerRepository.findById(offerId);

    if (offer == null) {
      throw const DriverRideOfferActionException(
        DriverRideOfferActionConflict.offerNotFound,
      );
    }

    if (offer.driverId != driverId) {
      throw const DriverRideOfferActionException(
        DriverRideOfferActionConflict.offerDoesNotBelongToDriver,
      );
    }
  }
}
import 'ride_offer.dart';

typedef ExpireDueOffers = Future<List<RideOffer>> Function({
  required DateTime now,
});

typedef ContinueAutomaticDispatch = Future<RideOffer?> Function({
  required String rideId,
});

class RideOfferTimeoutProcessor {
  final ExpireDueOffers expireDueOffers;
  final ContinueAutomaticDispatch continueRide;

  const RideOfferTimeoutProcessor({
    required this.expireDueOffers,
    required this.continueRide,
  });

  Future<List<RideOffer>> process({required DateTime now}) async {
    final expiredOffers = await expireDueOffers(now: now.toUtc());

    for (final offer in expiredOffers) {
      await continueRide(rideId: offer.rideId);
    }

    return List.unmodifiable(expiredOffers);
  }
}

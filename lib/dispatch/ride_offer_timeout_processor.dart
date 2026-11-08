import 'ride_offer.dart';

typedef ExpireDueOffers = Future<List<RideOffer>> Function({
  required DateTime now,
});

typedef ContinueAutomaticDispatch = Future<RideOffer?> Function({
  required String rideId,
});

typedef RecordIgnoredOffer = Future<void> Function({
  required RideOffer offer,
  required DateTime now,
});
typedef ProcessOutboxAction = Future<void> Function({required String actionId});

class RideOfferTimeoutProcessor {
  final ExpireDueOffers expireDueOffers;
  final ContinueAutomaticDispatch continueRide;
  final RecordIgnoredOffer? recordIgnoredOffer;
  final ProcessOutboxAction? processOutboxAction;

  const RideOfferTimeoutProcessor({
    required this.expireDueOffers,
    required this.continueRide,
    this.recordIgnoredOffer,
    this.processOutboxAction,
  });

  Future<List<RideOffer>> process({required DateTime now}) async {
    final nowUtc = now.toUtc();
    final expiredOffers = await expireDueOffers(now: nowUtc);

    for (final offer in expiredOffers) {
      if (offer.displayedAt != null && recordIgnoredOffer != null) {
        await recordIgnoredOffer!(offer: offer, now: nowUtc);
      }

      final process = processOutboxAction;
      if (process != null) {
        await process(actionId: 'timeout:${offer.id}');
      } else {
        await continueRide(rideId: offer.rideId);
      }
    }

    return List.unmodifiable(expiredOffers);
  }
}

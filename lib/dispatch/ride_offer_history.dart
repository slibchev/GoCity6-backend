import 'ride_offer.dart';

class RideOfferHistory {
  final String rideId;
  final int maxAttempts;
  final List<RideOffer> offers;

  RideOfferHistory({
    required this.rideId,
    required this.maxAttempts,
    required Iterable<RideOffer> offers,
  }) : offers = List<RideOffer>.unmodifiable(offers) {
    if (maxAttempts <= 0) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'Maximum attempts must be positive.',
      );
    }

    if (this.offers.any((offer) => offer.rideId != rideId)) {
      throw ArgumentError(
        'All offers must belong to ride $rideId.',
      );
    }
  }

  int get attemptsUsed => offers.length;

  bool get maxAttemptsReached =>
      attemptsUsed >= maxAttempts;

  bool get hasPendingOffer =>
      offers.any(
        (offer) => offer.status == RideOfferStatus.pending,
      );

  bool get hasAcceptedOffer =>
      offers.any(
        (offer) => offer.status == RideOfferStatus.accepted,
      );

  bool hasBeenOfferedToDriver(String driverId) {
    return offers.any(
      (offer) => offer.driverId == driverId,
    );
  }

  bool get canCreateAnotherOffer {
    return !maxAttemptsReached &&
        !hasPendingOffer &&
        !hasAcceptedOffer;
  }

  bool canOfferDriver(String driverId) {
    return canCreateAnotherOffer &&
        !hasBeenOfferedToDriver(driverId);
  }
}
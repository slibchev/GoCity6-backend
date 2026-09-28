import 'ride_offer.dart';

class RideOfferHistory {
  final String rideId;
  final List<RideOffer> offers;

  RideOfferHistory({required this.rideId, required Iterable<RideOffer> offers})
    : offers = List<RideOffer>.unmodifiable(offers) {
    if (this.offers.any((offer) => offer.rideId != rideId)) {
      throw ArgumentError('All offers must belong to ride $rideId.');
    }
  }

  int get attemptsUsed => offers.length;

  bool get hasPendingOffer =>
      offers.any((offer) => offer.status == RideOfferStatus.pending);

  bool get hasAcceptedOffer =>
      offers.any((offer) => offer.status == RideOfferStatus.accepted);

  bool hasBeenOfferedToDriver(
    String driverId, {
    int dispatchRound = RideOffer.normalDispatchRound,
  }) {
    _validateDispatchRound(dispatchRound);

    return offers.any(
      (offer) =>
          offer.driverId == driverId && offer.dispatchRound == dispatchRound,
    );
  }

  bool get canCreateAnotherOffer {
    return !hasPendingOffer && !hasAcceptedOffer;
  }

  bool canOfferDriver(
    String driverId, {
    int dispatchRound = RideOffer.normalDispatchRound,
  }) {
    _validateDispatchRound(dispatchRound);

    return canCreateAnotherOffer &&
        !hasBeenOfferedToDriver(driverId, dispatchRound: dispatchRound);
  }

  RideOfferHistory addOffer(RideOffer offer) {
    if (offer.rideId != rideId) {
      throw ArgumentError('Offer ${offer.id} does not belong to ride $rideId.');
    }

    if (!canOfferDriver(offer.driverId, dispatchRound: offer.dispatchRound)) {
      throw StateError(
        'Cannot create another offer for driver '
        '${offer.driverId} in dispatch round '
        '${offer.dispatchRound}.',
      );
    }

    return RideOfferHistory(rideId: rideId, offers: [...offers, offer]);
  }

  RideOfferHistory replaceOffer(RideOffer offer) {
    if (offer.rideId != rideId) {
      throw ArgumentError('Offer ${offer.id} does not belong to ride $rideId.');
    }

    final index = offers.indexWhere(
      (existingOffer) => existingOffer.id == offer.id,
    );

    if (index == -1) {
      throw ArgumentError('Offer ${offer.id} was not found.');
    }

    final updatedOffers = [...offers];
    updatedOffers[index] = offer;

    return RideOfferHistory(rideId: rideId, offers: updatedOffers);
  }

  static void _validateDispatchRound(int dispatchRound) {
    if (dispatchRound != RideOffer.normalDispatchRound &&
        dispatchRound != RideOffer.bonusDispatchRound) {
      throw ArgumentError.value(
        dispatchRound,
        'dispatchRound',
        'Dispatch round must be 1 or 2.',
      );
    }
  }
}

import 'atomic_ride_offer_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_repository.dart';

class RideOfferExpirationService {
  final RideOfferRepository offerRepository;
  final AtomicRideOfferRepository atomicOfferRepository;

  const RideOfferExpirationService({
    required this.offerRepository,
    required this.atomicOfferRepository,
  });

  Future<List<RideOffer>> expireDueOffers({required DateTime now}) async {
    final nowUtc = now.toUtc();

    final dueOffers = await offerRepository.findPendingExpiredAt(nowUtc);

    final expiredOffers = <RideOffer>[];

    for (final offer in dueOffers) {
      final expired = await atomicOfferRepository.expirePendingOffer(
        offerId: offer.id,
        now: nowUtc,
      );

      expiredOffers.add(expired);
    }

    return List.unmodifiable(expiredOffers);
  }
}

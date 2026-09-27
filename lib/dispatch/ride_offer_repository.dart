import 'ride_offer.dart';

abstract interface class RideOfferRepository {
  Future<RideOffer?> findById(String id);

  Future<List<RideOffer>> findByRideId(String rideId);

  Future<List<RideOffer>> findPendingExpiredAt(DateTime now);

  Future<void> create(RideOffer offer);

  Future<bool> resolve(RideOffer offer);
}

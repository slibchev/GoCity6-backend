import 'ride_offer.dart';

class DriverOfferStatusRecord {
  final String offerId;
  final String rideId;
  final DateTime offeredAt;
  final DateTime expiresAt;
  final RideOfferStatus status;
  final DateTime? resolvedAt;
  final DateTime? displayedAt;

  const DriverOfferStatusRecord({
    required this.offerId,
    required this.rideId,
    required this.offeredAt,
    required this.expiresAt,
    required this.status,
    required this.resolvedAt,
    required this.displayedAt,
  });
}

abstract interface class DriverOfferStatusRepository {
  Future<DriverOfferStatusRecord?> findForDriver({
    required String offerId,
    required String driverId,
  });
}

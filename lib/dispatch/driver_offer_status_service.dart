import 'driver_offer_status_repository.dart';
import 'ride_offer.dart';

class DriverOfferStatusNotFoundException implements Exception {
  const DriverOfferStatusNotFoundException();
}

class DriverOfferStatus {
  final String offerId;
  final String rideId;
  final RideOfferStatus status;
  final DateTime offeredAt;
  final DateTime expiresAt;
  final DateTime? resolvedAt;
  final DateTime? displayedAt;

  const DriverOfferStatus({
    required this.offerId,
    required this.rideId,
    required this.status,
    required this.offeredAt,
    required this.expiresAt,
    required this.resolvedAt,
    required this.displayedAt,
  });
}

class DriverOfferStatusService {
  final DriverOfferStatusRepository repository;
  final DateTime Function() now;

  DriverOfferStatusService({required this.repository, DateTime Function()? now})
    : now = now ?? DateTime.now;

  Future<DriverOfferStatus> findForDriver({
    required String offerId,
    required String driverId,
  }) async {
    final record = await repository.findForDriver(
      offerId: offerId,
      driverId: driverId,
    );

    if (record == null) {
      throw const DriverOfferStatusNotFoundException();
    }

    final effectiveStatus =
        record.status == RideOfferStatus.pending &&
            !now().toUtc().isBefore(record.expiresAt.toUtc())
        ? RideOfferStatus.expired
        : record.status;

    return DriverOfferStatus(
      offerId: record.offerId,
      rideId: record.rideId,
      status: effectiveStatus,
      offeredAt: record.offeredAt.toUtc(),
      expiresAt: record.expiresAt.toUtc(),
      resolvedAt: record.resolvedAt?.toUtc(),
      displayedAt: record.displayedAt?.toUtc(),
    );
  }
}

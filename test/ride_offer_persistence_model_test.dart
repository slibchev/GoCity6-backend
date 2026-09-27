import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:test/test.dart';

void main() {
  final offeredAt = DateTime.utc(2026, 9, 27, 12);

  final expiresAt = offeredAt.add(const Duration(seconds: 15));

  group('RideOffer.restore', () {
    test('restores pending offer', () {
      final offer = RideOffer.restore(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        expiresAt: expiresAt,
        status: RideOfferStatus.pending,
        resolvedAt: null,
      );

      expect(offer.status, RideOfferStatus.pending);
      expect(offer.resolvedAt, isNull);
      expect(offer.driverId, 'driver-001');
    });

    test('restores rejected offer', () {
      final resolvedAt = offeredAt.add(const Duration(seconds: 5));

      final offer = RideOffer.restore(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        expiresAt: expiresAt,
        status: RideOfferStatus.rejected,
        resolvedAt: resolvedAt,
      );

      expect(offer.status, RideOfferStatus.rejected);
      expect(offer.resolvedAt, resolvedAt);
    });

    test('rejects pending offer with resolvedAt', () {
      expect(
        () => RideOffer.restore(
          id: 'offer-001',
          rideId: 'ride-001',
          driverId: 'driver-001',
          vehicleId: 'vehicle-001',
          etaSeconds: 300,
          distanceMeters: 700,
          offeredAt: offeredAt,
          expiresAt: expiresAt,
          status: RideOfferStatus.pending,
          resolvedAt: offeredAt.add(const Duration(seconds: 5)),
        ),
        throwsArgumentError,
      );
    });

    test('rejects accepted offer resolved at deadline', () {
      expect(
        () => RideOffer.restore(
          id: 'offer-001',
          rideId: 'ride-001',
          driverId: 'driver-001',
          vehicleId: 'vehicle-001',
          etaSeconds: 300,
          distanceMeters: 700,
          offeredAt: offeredAt,
          expiresAt: expiresAt,
          status: RideOfferStatus.accepted,
          resolvedAt: expiresAt,
        ),
        throwsArgumentError,
      );
    });
  });
}

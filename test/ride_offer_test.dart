import 'package:gocity6_backend/dispatch/dispatch_policy.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_history.dart';
import 'package:test/test.dart';

void main() {
  final offeredAt = DateTime.utc(2026, 9, 27, 10);

  RideOffer createOffer({
    String id = 'offer-001',
    String rideId = 'ride-001',
    String driverId = 'driver-001',
    int minute = 0,
  }) {
    return RideOffer.create(
      id: id,
      rideId: rideId,
      driverId: driverId,
      vehicleId: 'vehicle-$driverId',
      etaSeconds: 300,
      distanceMeters: 700,
      offeredAt: DateTime.utc(2026, 9, 27, 10, minute),
      timeout: const Duration(seconds: 15),
    );
  }

  group('RideOffer', () {
    test('dispatch policy uses 15 second timeout', () {
      const policy = DispatchPolicy();

      expect(policy.offerTimeout, const Duration(seconds: 15));
    });

    test('new offer is pending and expires after 15 seconds', () {
      final offer = RideOffer.create(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        timeout: const Duration(seconds: 15),
      );

      expect(offer.status, RideOfferStatus.pending);

      expect(offer.resolvedAt, isNull);

      expect(offer.expiresAt, offeredAt.add(const Duration(seconds: 15)));
    });

    test('driver can accept before deadline', () {
      final acceptedAt = offeredAt.add(const Duration(seconds: 10));

      final offer = RideOffer.create(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        timeout: const Duration(seconds: 15),
      ).accept(acceptedAt);

      expect(offer.status, RideOfferStatus.accepted);

      expect(offer.resolvedAt, acceptedAt);
    });

    test('driver can reject before deadline', () {
      final rejectedAt = offeredAt.add(const Duration(seconds: 7));

      final offer = RideOffer.create(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        timeout: const Duration(seconds: 15),
      ).reject(rejectedAt);

      expect(offer.status, RideOfferStatus.rejected);

      expect(offer.resolvedAt, rejectedAt);
    });

    test('pending offer expires at its deadline', () {
      final offer = RideOffer.create(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        timeout: const Duration(seconds: 15),
      );

      final expired = offer.expire(offer.expiresAt);

      expect(expired.status, RideOfferStatus.expired);
    });

    test('driver cannot accept at or after deadline', () {
      final offer = RideOffer.create(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        timeout: const Duration(seconds: 15),
      );

      expect(
        () => offer.accept(offer.expiresAt),
        throwsA(
          isA<RideOfferConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideOfferConflict.alreadyExpired,
          ),
        ),
      );
    });

    test('offer cannot expire before deadline', () {
      final offer = RideOffer.create(
        id: 'offer-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        offeredAt: offeredAt,
        timeout: const Duration(seconds: 15),
      );

      expect(
        () => offer.expire(offeredAt.add(const Duration(seconds: 14))),
        throwsA(
          isA<RideOfferConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideOfferConflict.notExpiredYet,
          ),
        ),
      );
    });
  });

  group('RideOfferHistory', () {
    test('tracks attempts and drivers already offered', () {
      final rejected = createOffer().reject(
        DateTime.utc(2026, 9, 27, 10, 0, 5),
      );

      final history = RideOfferHistory(rideId: 'ride-001', offers: [rejected]);

      expect(history.attemptsUsed, 1);

      expect(history.hasBeenOfferedToDriver('driver-001'), isTrue);

      expect(history.hasBeenOfferedToDriver('driver-002'), isFalse);
    });

    test('pending offer blocks another simultaneous offer', () {
      final history = RideOfferHistory(
        rideId: 'ride-001',
        offers: [createOffer()],
      );

      expect(history.hasPendingOffer, isTrue);

      expect(history.canCreateAnotherOffer, isFalse);
    });

    test('rejected offer allows next different driver', () {
      final rejected = createOffer().reject(
        DateTime.utc(2026, 9, 27, 10, 0, 5),
      );

      final history = RideOfferHistory(rideId: 'ride-001', offers: [rejected]);

      expect(history.canOfferDriver('driver-001'), isFalse);

      expect(history.canOfferDriver('driver-002'), isTrue);
    });

    test('more than three failed offers still allow a new driver', () {
      final offers = <RideOffer>[];

      for (var i = 1; i <= 8; i++) {
        final offer = createOffer(
          id: 'offer-$i',
          driverId: 'driver-$i',
          minute: i,
        ).reject(DateTime.utc(2026, 9, 27, 10, i, 5));

        offers.add(offer);
      }

      final history = RideOfferHistory(rideId: 'ride-001', offers: offers);

      expect(history.attemptsUsed, 8);

      expect(history.canCreateAnotherOffer, isTrue);

      expect(history.canOfferDriver('driver-009'), isTrue);
    });

    test('same driver cannot receive same ride twice', () {
      final rejected = createOffer(driverId: 'driver-001')
          .reject(DateTime.utc(2026, 9, 27, 10, 0, 5));

      final history = RideOfferHistory(rideId: 'ride-001', offers: [rejected]);

      expect(history.canOfferDriver('driver-001'), isFalse);
    });

    test('accepted offer stops automatic offering', () {
      final accepted = createOffer().accept(
        DateTime.utc(2026, 9, 27, 10, 0, 5),
      );

      final history = RideOfferHistory(rideId: 'ride-001', offers: [accepted]);

      expect(history.hasAcceptedOffer, isTrue);

      expect(history.canCreateAnotherOffer, isFalse);
    });
  });
}

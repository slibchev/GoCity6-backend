import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_timeout_processor.dart';
import 'package:test/test.dart';

void main() {
  test('continues dispatch for every expired offer', () async {
    final now = DateTime.utc(2026, 10, 9, 10, 30);

    final expiredOffer = RideOffer.create(
      id: 'offer-001',
      rideId: 'ride-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 120,
      distanceMeters: 1000,
      offeredAt: now.subtract(const Duration(seconds: 20)),
      timeout: const Duration(seconds: 15),
    ).expire(now);

    final continuedRideIds = <String>[];

    final processor = RideOfferTimeoutProcessor(
      expireDueOffers: ({required DateTime now}) async {
        return [expiredOffer];
      },
      continueRide: ({required String rideId}) async {
        continuedRideIds.add(rideId);
        return null;
      },
    );

    final result = await processor.process(now: now);

    expect(result, hasLength(1));
    expect(result.single.id, 'offer-001');
    expect(continuedRideIds, ['ride-001']);
  });
  test('expiration preserves displayed acknowledgement', () {
    final now = DateTime.utc(2026, 10, 16, 11, 0);
    final displayedAt = now.subtract(const Duration(seconds: 17));

    final offer = RideOffer.restore(
      id: 'offer-displayed',
      rideId: 'ride-displayed',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 120,
      distanceMeters: 1000,
      offeredAt: now.subtract(const Duration(seconds: 20)),
      expiresAt: now.subtract(const Duration(seconds: 5)),
      status: RideOfferStatus.pending,
      resolvedAt: null,
      displayedAt: displayedAt,
    );

    final expired = offer.expire(now);

    expect(expired.status, RideOfferStatus.expired);
    expect(expired.displayedAt, displayedAt);
  });

  test('expiration without display keeps acknowledgement null', () {
    final now = DateTime.utc(2026, 10, 16, 11, 0);

    final offer = RideOffer.create(
      id: 'offer-not-displayed',
      rideId: 'ride-not-displayed',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 120,
      distanceMeters: 1000,
      offeredAt: now.subtract(const Duration(seconds: 20)),
      timeout: const Duration(seconds: 15),
    );

    final expired = offer.expire(now);

    expect(expired.status, RideOfferStatus.expired);
    expect(expired.displayedAt, isNull);
  });
  test('records ignored offers only when displayed', () async {
    final now = DateTime.utc(2026, 10, 16, 12);

    RideOffer makeExpiredOffer(String id, DateTime? displayedAt) {
      return RideOffer.restore(
        id: id,
        rideId: 'ride-$id',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        etaSeconds: 120,
        distanceMeters: 1000,
        offeredAt: now.subtract(const Duration(seconds: 20)),
        expiresAt: now.subtract(const Duration(seconds: 5)),
        status: RideOfferStatus.expired,
        resolvedAt: now,
        displayedAt: displayedAt,
      );
    }

    final displayed = makeExpiredOffer(
      'displayed',
      now.subtract(const Duration(seconds: 17)),
    );

    final notDisplayed = makeExpiredOffer('not-displayed', null);

    final ignoredOfferIds = <String>[];
    final continuedRideIds = <String>[];

    final processor = RideOfferTimeoutProcessor(
      expireDueOffers: ({required DateTime now}) async {
        return [displayed, notDisplayed];
      },
      recordIgnoredOffer:
          ({required RideOffer offer, required DateTime now}) async {
            ignoredOfferIds.add(offer.id);
          },
      continueRide: ({required String rideId}) async {
        continuedRideIds.add(rideId);
        return null;
      },
    );

    await processor.process(now: now);

    expect(ignoredOfferIds, ['displayed']);
    expect(continuedRideIds, ['ride-displayed', 'ride-not-displayed']);
  });
}

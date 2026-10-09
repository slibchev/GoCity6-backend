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
}

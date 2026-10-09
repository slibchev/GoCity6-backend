import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_expiration_service.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:test/test.dart';

void main() {
  test('expires pending offers that are due', () async {
    final now = DateTime.utc(2026, 10, 9, 9, 5);

    final offer = RideOffer.create(
      id: 'offer-001',
      rideId: 'ride-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 120,
      distanceMeters: 1000,
      offeredAt: now.subtract(const Duration(seconds: 20)),
      timeout: const Duration(seconds: 15),
    );

    final offerRepository = _FakeRideOfferRepository(dueOffers: [offer]);

    final atomicOfferRepository = _FakeAtomicRideOfferRepository();

    final service = RideOfferExpirationService(
      offerRepository: offerRepository,
      atomicOfferRepository: atomicOfferRepository,
    );

    final result = await service.expireDueOffers(now: now);

    expect(result, hasLength(1));
    expect(result.single.id, 'offer-001');
    expect(result.single.status, RideOfferStatus.expired);

    expect(atomicOfferRepository.expiredOfferIds, ['offer-001']);
  });
}

class _FakeRideOfferRepository implements RideOfferRepository {
  _FakeRideOfferRepository({required this.dueOffers});

  final List<RideOffer> dueOffers;

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async {
    return dueOffers;
  }

  @override
  Future<RideOffer?> findById(String id) async {
    return null;
  }

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async {
    return [];
  }

  @override
  Future<void> create(RideOffer offer) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<bool> resolve(RideOffer offer) {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeAtomicRideOfferRepository implements AtomicRideOfferRepository {
  final List<String> expiredOfferIds = [];

  @override
  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  }) async {
    expiredOfferIds.add(offerId);

    final offer = RideOffer.create(
      id: offerId,
      rideId: 'ride-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      etaSeconds: 120,
      distanceMeters: 1000,
      offeredAt: now.subtract(const Duration(seconds: 20)),
      timeout: const Duration(seconds: 15),
    );

    return offer.expire(now);
  }

  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> movePendingRideToWaitingForVehicle({required String rideId}) {
    throw UnsupportedError('Not needed by this test.');
  }
}

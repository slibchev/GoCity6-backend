import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/driver_ride_offer_action_service.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 6, 20);

  RideOffer buildOffer({
    String driverId = 'driver-001',
  }) {
    return RideOffer.create(
      id: 'offer-001',
      rideId: 'ride-001',
      driverId: driverId,
      vehicleId: 'vehicle-001',
      etaSeconds: 120,
      distanceMeters: 900,
      offeredAt: now.subtract(const Duration(seconds: 5)),
      timeout: const Duration(seconds: 15),
    );
  }

  test('accepts offer owned by authenticated driver', () async {
    final offer = buildOffer();

    final atomicRepository = _FakeAtomicRideOfferRepository(
      offer: offer,
    );

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(
        offer: offer,
      ),
      atomicOfferRepository: atomicRepository,
    );

    final result = await service.accept(
      driverId: 'driver-001',
      offerId: 'offer-001',
      now: now,
    );

    expect(result.status, RideOfferStatus.accepted);
    expect(atomicRepository.acceptCalls, 1);
    expect(atomicRepository.lastOfferId, 'offer-001');
  });

  test('rejects offer owned by authenticated driver', () async {
    final offer = buildOffer();

    final atomicRepository = _FakeAtomicRideOfferRepository(
      offer: offer,
    );

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(
        offer: offer,
      ),
      atomicOfferRepository: atomicRepository,
    );

    final result = await service.reject(
      driverId: 'driver-001',
      offerId: 'offer-001',
      now: now,
    );

    expect(result.status, RideOfferStatus.rejected);
    expect(atomicRepository.rejectCalls, 1);
    expect(atomicRepository.lastOfferId, 'offer-001');
  });

  test('rejects action on offer owned by another driver', () async {
    final offer = buildOffer(
      driverId: 'driver-other',
    );

    final atomicRepository = _FakeAtomicRideOfferRepository(
      offer: offer,
    );

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(
        offer: offer,
      ),
      atomicOfferRepository: atomicRepository,
    );

    expect(
      service.accept(
        driverId: 'driver-001',
        offerId: 'offer-001',
        now: now,
      ),
      throwsA(
        isA<DriverRideOfferActionException>().having(
          (error) => error.conflict,
          'conflict',
          DriverRideOfferActionConflict.offerDoesNotBelongToDriver,
        ),
      ),
    );

    expect(atomicRepository.acceptCalls, 0);
  });

  test('rejects action when offer does not exist', () async {
    final atomicRepository = _FakeAtomicRideOfferRepository();

    final service = DriverRideOfferActionService(
      offerRepository: _FakeRideOfferRepository(),
      atomicOfferRepository: atomicRepository,
    );

    expect(
      service.reject(
        driverId: 'driver-001',
        offerId: 'missing-offer',
        now: now,
      ),
      throwsA(
        isA<DriverRideOfferActionException>().having(
          (error) => error.conflict,
          'conflict',
          DriverRideOfferActionConflict.offerNotFound,
        ),
      ),
    );

    expect(atomicRepository.rejectCalls, 0);
  });
}

class _FakeRideOfferRepository implements RideOfferRepository {
  _FakeRideOfferRepository({
    this.offer,
  });

  final RideOffer? offer;

  @override
  Future<RideOffer?> findById(String id) async {
    if (offer?.id == id) {
      return offer;
    }

    return null;
  }

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> create(RideOffer offer) async {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<bool> resolve(RideOffer offer) async {
    throw UnsupportedError('Not needed by this test.');
  }
}

class _FakeAtomicRideOfferRepository
    implements AtomicRideOfferRepository {
  _FakeAtomicRideOfferRepository({
    this.offer,
  });

  final RideOffer? offer;

  int acceptCalls = 0;
  int rejectCalls = 0;
  String? lastOfferId;

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) async {
    acceptCalls += 1;
    lastOfferId = offerId;

    return offer!.accept(now);
  }

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) async {
    rejectCalls += 1;
    lastOfferId = offerId;

    return offer!.reject(now);
  }

  @override
  Future<RideOffer> createPendingOffer({
    required RideOffer offer,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> movePendingRideToWaitingForVehicle({
    required String rideId,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }
}
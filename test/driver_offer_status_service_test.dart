import 'package:gocity6_backend/dispatch/driver_offer_status_repository.dart';
import 'package:gocity6_backend/dispatch/driver_offer_status_service.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:test/test.dart';

void main() {
  final offeredAt = DateTime.utc(2026, 10, 23, 10);
  final expiresAt = offeredAt.add(const Duration(seconds: 15));

  DriverOfferStatusRecord record({
    RideOfferStatus status = RideOfferStatus.pending,
    DateTime? resolvedAt,
  }) {
    return DriverOfferStatusRecord(
      offerId: 'offer-001',
      rideId: 'ride-001',
      offeredAt: offeredAt,
      expiresAt: expiresAt,
      status: status,
      resolvedAt: resolvedAt,
      displayedAt: null,
    );
  }

  test('returns an owned pending offer before expiration', () async {
    final repository = _FakeDriverOfferStatusRepository(record());
    final service = DriverOfferStatusService(
      repository: repository,
      now: () => expiresAt.subtract(const Duration(microseconds: 1)),
    );

    final status = await service.findForDriver(
      offerId: 'offer-001',
      driverId: 'driver-001',
    );

    expect(status.status, RideOfferStatus.pending);
    expect(status.offerId, 'offer-001');
    expect(repository.lastOfferId, 'offer-001');
    expect(repository.lastDriverId, 'driver-001');
  });

  test(
    'reports pending offer as expired at the exact expiration time',
    () async {
      final repository = _FakeDriverOfferStatusRepository(record());
      final service = DriverOfferStatusService(
        repository: repository,
        now: () => expiresAt,
      );

      final status = await service.findForDriver(
        offerId: 'offer-001',
        driverId: 'driver-001',
      );

      expect(status.status, RideOfferStatus.expired);
      expect(status.resolvedAt, isNull);
      expect(repository.readCount, 1);
      expect(repository.writeCount, 0);
      expect(repository.penaltyCount, 0);
    },
  );

  test(
    'reports pending offer as expired after expiration without writing',
    () async {
      final repository = _FakeDriverOfferStatusRepository(record());
      final service = DriverOfferStatusService(
        repository: repository,
        now: () => expiresAt.add(const Duration(seconds: 1)),
      );

      final status = await service.findForDriver(
        offerId: 'offer-001',
        driverId: 'driver-001',
      );

      expect(status.status, RideOfferStatus.expired);
      expect(repository.writeCount, 0);
      expect(repository.penaltyCount, 0);
    },
  );

  for (final terminalStatus in [
    RideOfferStatus.accepted,
    RideOfferStatus.rejected,
    RideOfferStatus.expired,
  ]) {
    test('preserves stored ${terminalStatus.name} status', () async {
      final resolvedAt = terminalStatus == RideOfferStatus.expired
          ? expiresAt
          : offeredAt.add(const Duration(seconds: 2));
      final repository = _FakeDriverOfferStatusRepository(
        record(status: terminalStatus, resolvedAt: resolvedAt),
      );
      final service = DriverOfferStatusService(
        repository: repository,
        now: () => expiresAt.add(const Duration(hours: 1)),
      );

      final status = await service.findForDriver(
        offerId: 'offer-001',
        driverId: 'driver-001',
      );

      expect(status.status, terminalStatus);
      expect(status.resolvedAt, resolvedAt);
    });
  }

  test('throws not found for an offer not owned by the driver', () async {
    final repository = _FakeDriverOfferStatusRepository(
      null,
      expectedDriverId: 'driver-owner',
    );
    final service = DriverOfferStatusService(
      repository: repository,
      now: () => offeredAt,
    );

    await expectLater(
      service.findForDriver(offerId: 'offer-001', driverId: 'other-driver'),
      throwsA(isA<DriverOfferStatusNotFoundException>()),
    );
    expect(repository.writeCount, 0);
    expect(repository.penaltyCount, 0);
  });
}

class _FakeDriverOfferStatusRepository implements DriverOfferStatusRepository {
  _FakeDriverOfferStatusRepository(
    this.record, {
    this.expectedDriverId = 'driver-001',
  });

  final DriverOfferStatusRecord? record;
  final String expectedDriverId;
  String? lastOfferId;
  String? lastDriverId;
  int readCount = 0;
  int writeCount = 0;
  int penaltyCount = 0;

  @override
  Future<DriverOfferStatusRecord?> findForDriver({
    required String offerId,
    required String driverId,
  }) async {
    readCount++;
    lastOfferId = offerId;
    lastDriverId = driverId;
    if (driverId != expectedDriverId || record?.offerId != offerId) {
      return null;
    }
    return record;
  }
}

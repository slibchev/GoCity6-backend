import 'dart:convert';

import 'package:gocity6_backend/auth/driver_token_service.dart';
import 'package:gocity6_backend/dispatch/driver_offer_status_repository.dart';
import 'package:gocity6_backend/dispatch/driver_offer_status_route.dart';
import 'package:gocity6_backend/dispatch/driver_offer_status_service.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  const jwtSecret = 'city6-driver-offer-status-test-secret';
  const driverId = 'driver-owner';
  const offerId = 'offer-001';
  final offeredAt = DateTime.utc(2026, 10, 23, 10);
  final expiresAt = offeredAt.add(const Duration(seconds: 15));
  final tokenService = DriverTokenService(secret: jwtSecret);
  final token = tokenService.createToken(
    driverId: driverId,
    username: 'offer-status-test',
  );

  DriverOfferStatusRecord record({
    RideOfferStatus status = RideOfferStatus.pending,
    DateTime? resolvedAt,
  }) {
    return DriverOfferStatusRecord(
      offerId: offerId,
      rideId: 'ride-001',
      offeredAt: offeredAt,
      expiresAt: expiresAt,
      status: status,
      resolvedAt: resolvedAt,
      displayedAt: null,
    );
  }

  Future<Response> callRoute({
    required DriverOfferStatusService? statusService,
    bool tokenDependencyConfigured = true,
    String? authorization,
    String path = '/driver/offers/$offerId',
  }) async {
    final router = Router();
    registerDriverOfferStatusRoute(
      router,
      tokenService: tokenDependencyConfigured ? tokenService : null,
      statusService: statusService,
    );
    final headers = <String, String>{};
    if (authorization != null) {
      headers['authorization'] = authorization;
    }
    return router.call(
      Request('GET', Uri.parse('http://localhost$path'), headers: headers),
    );
  }

  DriverOfferStatusService service(
    _FakeDriverOfferStatusRepository repository, {
    DateTime Function()? now,
  }) {
    return DriverOfferStatusService(repository: repository, now: now);
  }

  test('returns only the offer status fields for the JWT owner', () async {
    final repository = _FakeDriverOfferStatusRepository(record());
    final response = await callRoute(
      statusService: service(repository, now: () => offeredAt),
      authorization: 'Bearer $token',
      path: '/driver/offers/$offerId?driverId=another-driver',
    );

    expect(response.statusCode, 200);
    expect(response.headers['cache-control'], 'no-store');
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body.keys.toSet(), {
      'offerId',
      'rideId',
      'status',
      'offeredAt',
      'expiresAt',
      'resolvedAt',
      'displayedAt',
    });
    expect(body['status'], 'pending');
    expect(repository.lastDriverId, driverId);
    expect(repository.readCount, 1);
    expect(repository.writeCount, 0);
    expect(repository.penaltyCount, 0);
  });

  for (final terminalStatus in [
    RideOfferStatus.accepted,
    RideOfferStatus.rejected,
    RideOfferStatus.expired,
  ]) {
    test('returns ${terminalStatus.name} status over HTTP', () async {
      final resolvedAt = terminalStatus == RideOfferStatus.expired
          ? expiresAt
          : offeredAt.add(const Duration(seconds: 2));
      final repository = _FakeDriverOfferStatusRepository(
        record(status: terminalStatus, resolvedAt: resolvedAt),
      );
      final response = await callRoute(
        statusService: service(repository, now: () => expiresAt),
        authorization: 'Bearer $token',
      );

      expect(response.statusCode, 200);
      expect(response.headers['cache-control'], 'no-store');
      final body = jsonDecode(await response.readAsString());
      expect(body['status'], terminalStatus.name);
      expect(repository.writeCount, 0);
      expect(repository.penaltyCount, 0);
    });
  }

  test(
    'reports pending before expiry and effective expired at expiry',
    () async {
      final beforeExpiry = _FakeDriverOfferStatusRepository(record());
      final beforeResponse = await callRoute(
        statusService: service(
          beforeExpiry,
          now: () => expiresAt.subtract(const Duration(microseconds: 1)),
        ),
        authorization: 'Bearer $token',
      );
      expect(beforeResponse.statusCode, 200);
      expect(
        (jsonDecode(await beforeResponse.readAsString()) as Map)['status'],
        'pending',
      );

      final atExpiry = _FakeDriverOfferStatusRepository(record());
      final afterResponse = await callRoute(
        statusService: service(atExpiry, now: () => expiresAt),
        authorization: 'Bearer $token',
      );
      expect(afterResponse.statusCode, 200);
      expect(afterResponse.headers['cache-control'], 'no-store');
      expect(
        (jsonDecode(await afterResponse.readAsString()) as Map)['status'],
        'expired',
      );
      expect(atExpiry.writeCount, 0);
      expect(atExpiry.penaltyCount, 0);
    },
  );

  test('returns 401 for missing and invalid JWT', () async {
    final repository = _FakeDriverOfferStatusRepository(record());
    final statusService = service(repository, now: () => offeredAt);

    final missing = await callRoute(statusService: statusService);
    expect(missing.statusCode, 401);
    expect(missing.headers['cache-control'], 'no-store');

    final invalid = await callRoute(
      statusService: statusService,
      authorization: 'Bearer invalid-token',
    );
    expect(invalid.statusCode, 401);
    expect(repository.readCount, 0);
  });

  test('returns 401 for an expired JWT', () async {
    final expiredToken = DriverTokenService(
      secret: jwtSecret,
      tokenLifetime: const Duration(seconds: -1),
    ).createToken(driverId: driverId, username: 'offer-status-test');
    final repository = _FakeDriverOfferStatusRepository(record());

    final response = await callRoute(
      statusService: service(repository, now: () => offeredAt),
      authorization: 'Bearer $expiredToken',
    );

    expect(response.statusCode, 401);
    expect(repository.readCount, 0);
  });

  test('returns the same 404 for another driver and a missing offer', () async {
    final foreignRepository = _FakeDriverOfferStatusRepository(
      record(),
      expectedDriverId: 'another-driver',
    );
    final foreignService = service(foreignRepository, now: () => offeredAt);

    final foreignOffer = await callRoute(
      statusService: foreignService,
      authorization: 'Bearer $token',
    );
    expect(foreignOffer.statusCode, 404);
    expect(foreignOffer.headers['cache-control'], 'no-store');
    final foreignBody = await foreignOffer.readAsString();

    final missingRepository = _FakeDriverOfferStatusRepository(null);
    final missingOffer = await callRoute(
      statusService: service(missingRepository, now: () => offeredAt),
      authorization: 'Bearer $token',
      path: '/driver/offers/missing-offer',
    );
    expect(missingOffer.statusCode, 404);
    expect(await missingOffer.readAsString(), foreignBody);
  });

  test('returns 503 when the status dependency is not configured', () async {
    final response = await callRoute(
      statusService: null,
      authorization: 'Bearer $token',
    );

    expect(response.statusCode, 503);
    expect(response.headers['cache-control'], 'no-store');

    final missingTokenDependency = await callRoute(
      statusService: service(
        _FakeDriverOfferStatusRepository(record()),
        now: () => offeredAt,
      ),
      tokenDependencyConfigured: false,
    );
    expect(missingTokenDependency.statusCode, 503);
  });

  test('returns a generic 500 for repository errors without writes', () async {
    final repository = _FakeDriverOfferStatusRepository(
      record(),
      failReads: true,
    );
    final response = await callRoute(
      statusService: service(repository, now: () => offeredAt),
      authorization: 'Bearer $token',
    );

    expect(response.statusCode, 500);
    expect(response.headers['cache-control'], 'no-store');
    expect(
      await response.readAsString(),
      contains('Offer status lookup failed'),
    );
    expect(repository.writeCount, 0);
    expect(repository.penaltyCount, 0);
  });
}

class _FakeDriverOfferStatusRepository implements DriverOfferStatusRepository {
  _FakeDriverOfferStatusRepository(
    this.record, {
    this.expectedDriverId = 'driver-owner',
    this.failReads = false,
  });

  final DriverOfferStatusRecord? record;
  final String expectedDriverId;
  final bool failReads;
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
    if (failReads) {
      throw StateError('fake repository failure');
    }
    if (driverId != expectedDriverId || record?.offerId != offerId) {
      return null;
    }
    return record;
  }
}

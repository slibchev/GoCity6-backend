import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/auth/driver_token_service.dart';
import 'package:gocity6_backend/dispatch/driver_offer_status_route.dart';
import 'package:gocity6_backend/dispatch/driver_offer_status_service.dart';
import 'package:gocity6_backend/dispatch/postgres_ride_offer_repository.dart';

Future<Connection> _connectToCity6Test() async {
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  if (password == null || password.isEmpty) {
    fail('CITY6_TEST_DB_PASSWORD is required.');
  }

  final database = await Connection.open(
    Endpoint(
      host: 'localhost',
      port: 5432,
      database: 'city6_test',
      username: 'city6_app',
      password: password,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );

  try {
    final identity = await database.execute(
      'SELECT current_database() AS database_name, current_user AS role_name',
    );
    expect(identity.single.toColumnMap(), {
      'database_name': 'city6_test',
      'role_name': 'city6_app',
    });
    return database;
  } catch (_) {
    await database.close();
    rethrow;
  }
}

Future<Map<String, String>> _testScopeTableFingerprints(Session session) async {
  const tableNames = [
    'drivers',
    'vehicles',
    'rides',
    'ride_offers',
    'driver_dispatch_states',
    'ignored_offer_penalty_tracking',
  ];
  final fingerprints = <String, String>{};
  for (final tableName in tableNames) {
    final quotedTableName = '"${tableName.replaceAll('"', '""')}"';
    final result = await session.execute(
      Sql('''
        SELECT
          count(*)::text AS row_count,
          md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10)
            ORDER BY to_jsonb(t)::text), '')) AS fingerprint
        FROM public.$quotedTableName AS t
      '''),
    );
    final values = result.single.toColumnMap();
    fingerprints[tableName] = '${values['row_count']}:${values['fingerprint']}';
  }

  return fingerprints;
}

Future<String> _tableFingerprint(Session session, String tableName) async {
  final result = await session.execute(
    Sql('''
      SELECT
        count(*)::text AS row_count,
        md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10)
          ORDER BY to_jsonb(t)::text), '')) AS fingerprint
      FROM public.$tableName AS t
    '''),
  );
  final values = result.single.toColumnMap();
  return '${values['row_count']}:${values['fingerprint']}';
}

Future<void> _insertDriver(
  Session session, {
  required String id,
  required DateTime now,
}) async {
  await session.execute(
    Sql.named('''
      INSERT INTO drivers (
        id, username, password_hash,
        first_name, last_name, phone, created_at
      )
      VALUES (
        @id, @username, 'integration-test-hash',
        'PRIVATE-DRIVER-NAME', 'PRIVATE-DRIVER-LAST',
        'PRIVATE-PHONE-SENTINEL', @now
      )
    '''),
    parameters: {'id': id, 'username': 'offer-status-$id', 'now': now},
  );
}

Future<void> _insertVehicle(Session session, {required String id}) async {
  await session.execute(
    Sql.named('''
      INSERT INTO vehicles (id, plate_number, created_at)
      VALUES (@id, @plate, @now)
    '''),
    parameters: {
      'id': id,
      'plate': 'TEST-${id.replaceAll('-', '').substring(0, 12)}',
      'now': DateTime.now().toUtc(),
    },
  );
}

Future<void> _insertRide(
  Session session, {
  required String id,
  required DateTime now,
}) async {
  await session.execute(
    Sql.named('''
      INSERT INTO rides (
        id, pickup, destination, passengers, requested_at, status,
        pickup_latitude, pickup_longitude, meter_fare_minor
      )
      VALUES (
        @id, 'PRIVATE-PICKUP-SENTINEL', 'PRIVATE-DESTINATION-SENTINEL',
        1, @now, 'pending', 42.654321, 23.345678, 987654321
      )
    '''),
    parameters: {'id': id, 'now': now},
  );
}

Future<void> _insertOffer(
  Session session, {
  required String id,
  required String rideId,
  required String driverId,
  required String vehicleId,
  required DateTime offeredAt,
  required DateTime expiresAt,
  required String status,
  required DateTime? resolvedAt,
  required DateTime? displayedAt,
}) async {
  await session.execute(
    Sql.named('''
      INSERT INTO ride_offers (
        id, ride_id, driver_id, vehicle_id,
        source, eta_seconds, distance_meters,
        dispatch_round, bonus_minor,
        offered_at, expires_at, status, resolved_at, displayed_at
      )
      VALUES (
        @id, @rideId, @driverId, @vehicleId,
        'automatic', 120, 1000, 1, 0,
        @offeredAt, @expiresAt, @status, @resolvedAt, @displayedAt
      )
    '''),
    parameters: {
      'id': id,
      'rideId': rideId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'offeredAt': offeredAt,
      'expiresAt': expiresAt,
      'status': status,
      'resolvedAt': resolvedAt,
      'displayedAt': displayedAt,
    },
  );
}

Future<List<Map<String, dynamic>>> _readOfferPersistence(
  Session session,
  List<String> offerIds,
) async {
  final parameters = <String, Object?>{};
  final placeholders = <String>[];
  for (var index = 0; index < offerIds.length; index++) {
    final name = 'offer$index';
    parameters[name] = offerIds[index];
    placeholders.add('@$name');
  }

  final result = await session.execute(
    Sql.named('''
      SELECT id, status, resolved_at, displayed_at
      FROM ride_offers
      WHERE id IN (${placeholders.join(', ')})
      ORDER BY id
    '''),
    parameters: parameters,
  );
  return result.map((row) => row.toColumnMap()).toList();
}

class _RollbackAfterAssertions implements Exception {
  const _RollbackAfterAssertions();
}

void main() {
  test(
    'PostgreSQL driver offer status lookup is owner-filtered and read-only',
    () async {
      final database = await _connectToCity6Test();
      final before = await _testScopeTableFingerprints(database);
      Object? transactionFailure;
      StackTrace? transactionFailureStack;
      var rollbackSentinelReached = false;

      try {
        try {
          await database.runTx((transaction) async {
            final recoveryColumn = await transaction.execute("""
                SELECT data_type, is_nullable, column_default
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'driver_dispatch_states'
                  AND column_name = 'requires_completed_ride_after_penalty'
              """);
            expect(recoveryColumn, hasLength(1));
            expect(recoveryColumn.single.toColumnMap(), {
              'data_type': 'boolean',
              'is_nullable': 'NO',
              'column_default': 'false',
            });

            final offerColumns = await transaction.execute("""
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'ride_offers'
                  AND column_name IN (
                    'source', 'dispatch_round', 'bonus_minor',
                    'offered_at', 'expires_at', 'status',
                    'resolved_at', 'displayed_at'
                  )
              """);
            expect(offerColumns, hasLength(8));

            final pickupColumns = await transaction.execute("""
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'rides'
                  AND column_name IN ('pickup_latitude', 'pickup_longitude')
                  AND data_type = 'double precision'
                  AND is_nullable = 'YES'
              """);
            expect(pickupColumns, hasLength(2));

            final uuid = const Uuid();
            final now = DateTime.now().toUtc();
            final ownerId = uuid.v4();
            final otherDriverId = uuid.v4();
            final ownerVehicleId = uuid.v4();
            final otherVehicleId = uuid.v4();

            await _insertDriver(transaction, id: ownerId, now: now);
            await _insertDriver(transaction, id: otherDriverId, now: now);
            await _insertVehicle(transaction, id: ownerVehicleId);
            await _insertVehicle(transaction, id: otherVehicleId);

            final offerIds = <String>{
              for (var index = 0; index < 5; index++) uuid.v4(),
            };
            final rideIds = <String>{
              for (var index = 0; index < offerIds.length; index++) uuid.v4(),
            };
            for (final rideId in rideIds) {
              await _insertRide(transaction, id: rideId, now: now);
            }

            final ids = offerIds.toList(growable: false);
            final activePendingId = ids[0];
            final acceptedId = ids[1];
            final rejectedId = ids[2];
            final resolvedExpiredId = ids[3];
            final elapsedPendingId = ids[4];
            final rideList = rideIds.toList(growable: false);
            final activeRideId = rideList[0];
            final acceptedRideId = rideList[1];
            final rejectedRideId = rideList[2];
            final resolvedExpiredRideId = rideList[3];
            final elapsedRideId = rideList[4];

            final offeredAt = now.subtract(const Duration(seconds: 5));
            final displayedAt = now.subtract(const Duration(seconds: 4));
            final expiresAt = now.add(const Duration(seconds: 10));
            await _insertOffer(
              transaction,
              id: activePendingId,
              rideId: activeRideId,
              driverId: ownerId,
              vehicleId: ownerVehicleId,
              offeredAt: offeredAt,
              expiresAt: expiresAt,
              status: 'pending',
              resolvedAt: null,
              displayedAt: displayedAt,
            );

            final terminalOfferedAt = now.subtract(const Duration(seconds: 30));
            final terminalExpiresAt = now.subtract(const Duration(seconds: 15));
            final terminalResolvedAt = now.subtract(
              const Duration(seconds: 20),
            );
            await _insertOffer(
              transaction,
              id: acceptedId,
              rideId: acceptedRideId,
              driverId: ownerId,
              vehicleId: ownerVehicleId,
              offeredAt: terminalOfferedAt,
              expiresAt: terminalExpiresAt,
              status: 'accepted',
              resolvedAt: terminalResolvedAt,
              displayedAt: now.subtract(const Duration(seconds: 29)),
            );
            await _insertOffer(
              transaction,
              id: rejectedId,
              rideId: rejectedRideId,
              driverId: ownerId,
              vehicleId: ownerVehicleId,
              offeredAt: terminalOfferedAt,
              expiresAt: terminalExpiresAt,
              status: 'rejected',
              resolvedAt: terminalResolvedAt,
              displayedAt: now.subtract(const Duration(seconds: 29)),
            );
            await _insertOffer(
              transaction,
              id: resolvedExpiredId,
              rideId: resolvedExpiredRideId,
              driverId: ownerId,
              vehicleId: ownerVehicleId,
              offeredAt: terminalOfferedAt,
              expiresAt: terminalExpiresAt,
              status: 'expired',
              resolvedAt: terminalExpiresAt,
              displayedAt: null,
            );

            final elapsedOfferedAt = now.subtract(const Duration(seconds: 30));
            final elapsedExpiresAt = now.subtract(const Duration(seconds: 1));
            await _insertOffer(
              transaction,
              id: elapsedPendingId,
              rideId: elapsedRideId,
              driverId: otherDriverId,
              vehicleId: otherVehicleId,
              offeredAt: elapsedOfferedAt,
              expiresAt: elapsedExpiresAt,
              status: 'pending',
              resolvedAt: null,
              displayedAt: now.subtract(const Duration(seconds: 29)),
            );

            final dispatchStateBefore = await _tableFingerprint(
              transaction,
              'driver_dispatch_states',
            );
            final ignoredTrackingBefore = await _tableFingerprint(
              transaction,
              'ignored_offer_penalty_tracking',
            );
            final offerRowsBefore = await _readOfferPersistence(
              transaction,
              ids,
            );

            final tokenService = DriverTokenService(
              secret: 'city6-step947-integration-test-secret',
            );
            final otherTokenService = DriverTokenService(
              secret: 'city6-step947-integration-test-secret',
            );
            final ownerToken = tokenService.createToken(
              driverId: ownerId,
              username: 'offer-status-owner-test',
            );
            final otherToken = otherTokenService.createToken(
              driverId: otherDriverId,
              username: 'offer-status-other-test',
            );
            final invalidToken = 'not-a-valid-jwt';
            final expiredToken =
                DriverTokenService(
                  secret: 'city6-step947-integration-test-secret',
                  tokenLifetime: const Duration(seconds: -1),
                ).createToken(
                  driverId: ownerId,
                  username: 'offer-status-owner-test',
                );

            final repository = PostgresRideOfferRepository(
              database: transaction,
            );
            final service = DriverOfferStatusService(
              repository: repository,
              now: () => now,
            );
            final router = Router();
            registerDriverOfferStatusRoute(
              router,
              tokenService: tokenService,
              statusService: service,
            );

            Future<Response> getOffer(String offerId, {String? token}) {
              final headers = <String, String>{};
              if (token != null) {
                headers['authorization'] = 'Bearer $token';
              }
              return router.call(
                Request(
                  'GET',
                  Uri.parse('http://localhost/driver/offers/$offerId'),
                  headers: headers,
                ),
              );
            }

            Future<Map<String, dynamic>> expectSuccess(
              String offerId,
              String token,
              String expectedStatus,
            ) async {
              final response = await getOffer(offerId, token: token);
              expect(response.statusCode, 200);
              expect(response.headers['cache-control'], 'no-store');
              final body = jsonDecode(
                await response.readAsString(),
              ) as Map<String, dynamic>;
              expect(body.keys.toSet(), {
                'offerId',
                'rideId',
                'status',
                'offeredAt',
                'expiresAt',
                'resolvedAt',
                'displayedAt',
              });
              expect(body['status'], expectedStatus);
              expect(body.toString(), isNot(contains('PRIVATE-')));
              expect(body.toString(), isNot(contains('42.654321')));
              expect(body.toString(), isNot(contains('23.345678')));
              expect(body.toString(), isNot(contains('987654321')));
              return body;
            }

            final ownPending = await expectSuccess(
              activePendingId,
              ownerToken,
              'pending',
            );
            expect(ownPending['offerId'], activePendingId);
            expect(ownPending['rideId'], activeRideId);
            expect(ownPending['offeredAt'], offeredAt.toIso8601String());
            expect(ownPending['expiresAt'], expiresAt.toIso8601String());
            expect(ownPending['resolvedAt'], isNull);
            expect(ownPending['displayedAt'], displayedAt.toIso8601String());

            await expectSuccess(acceptedId, ownerToken, 'accepted');
            await expectSuccess(rejectedId, ownerToken, 'rejected');
            await expectSuccess(resolvedExpiredId, ownerToken, 'expired');
            await expectSuccess(elapsedPendingId, otherToken, 'expired');

            for (var attempt = 0; attempt < 3; attempt++) {
              await expectSuccess(elapsedPendingId, otherToken, 'expired');
              await expectSuccess(activePendingId, ownerToken, 'pending');
            }

            final foreignOfferResponse = await getOffer(
              activePendingId,
              token: otherToken,
            );
            final missingOfferResponse = await getOffer(
              uuid.v4(),
              token: ownerToken,
            );
            expect(foreignOfferResponse.statusCode, 404);
            expect(missingOfferResponse.statusCode, 404);
            expect(foreignOfferResponse.headers['cache-control'], 'no-store');
            expect(missingOfferResponse.headers['cache-control'], 'no-store');
            final foreignBody = await foreignOfferResponse.readAsString();
            final missingBody = await missingOfferResponse.readAsString();
            expect(foreignBody, missingBody);

            final noTokenResponse = await getOffer(activePendingId);
            final invalidTokenResponse = await getOffer(
              activePendingId,
              token: invalidToken,
            );
            final expiredTokenResponse = await getOffer(
              activePendingId,
              token: expiredToken,
            );
            expect(noTokenResponse.statusCode, 401);
            expect(invalidTokenResponse.statusCode, 401);
            expect(expiredTokenResponse.statusCode, 401);
            expect(noTokenResponse.headers['cache-control'], 'no-store');
            expect(invalidTokenResponse.headers['cache-control'], 'no-store');
            expect(expiredTokenResponse.headers['cache-control'], 'no-store');

            expect(
              await _readOfferPersistence(transaction, ids),
              offerRowsBefore,
            );
            expect(
              await _tableFingerprint(transaction, 'driver_dispatch_states'),
              dispatchStateBefore,
            );
            expect(
              await _tableFingerprint(
                transaction,
                'ignored_offer_penalty_tracking',
              ),
              ignoredTrackingBefore,
            );

            throw const _RollbackAfterAssertions();
          });
        } on _RollbackAfterAssertions {
          rollbackSentinelReached = true;
        } catch (error, stackTrace) {
          transactionFailure = error;
          transactionFailureStack = stackTrace;
        }

        expect(rollbackSentinelReached, isTrue);
        final after = await _testScopeTableFingerprints(database);
        expect(after, before);

        if (transactionFailure != null) {
          Error.throwWithStackTrace(
            transactionFailure,
            transactionFailureStack!,
          );
        }
      } finally {
        await database.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

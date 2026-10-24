import 'dart:io';

import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

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

Future<Map<String, String>> _tableFingerprints(Session session) async {
  const tableNames = [
    'drivers',
    'vehicles',
    'rides',
    'ride_offers',
    'driver_offer_action_outbox',
  ];
  final fingerprints = <String, String>{};
  for (final tableName in tableNames) {
    final result = await session.execute(
      Sql('''
        SELECT
          count(*)::text AS row_count,
          md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10)
            ORDER BY to_jsonb(t)::text), '')) AS fingerprint
        FROM public.$tableName AS t
      '''),
    );
    final row = result.single.toColumnMap();
    fingerprints[tableName] = '${row['row_count']}:${row['fingerprint']}';
  }
  return fingerprints;
}

Future<void> _insertDriver(
  Session session, {
  required String id,
  required DateTime now,
}) async {
  await session.execute(
    Sql.named('''
      INSERT INTO drivers (
        id, username, password_hash, first_name, last_name, phone, created_at
      ) VALUES (
        @id, @username, 'integration-test-hash',
        'Outbox-Test', 'Driver', @phone, @now
      )
    '''),
    parameters: {
      'id': id,
      'username': 'outbox-$id',
      'phone': 'outbox-test-$id',
      'now': now,
    },
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
      'plate': 'OUT-${id.replaceAll('-', '').substring(0, 12)}',
      'now': DateTime.now().toUtc(),
    },
  );
}

Future<void> _insertRideAndOffer(
  Session session, {
  required String rideId,
  required String offerId,
  required String driverId,
  required String vehicleId,
  required DateTime now,
}) async {
  await session.execute(
    Sql.named('''
      INSERT INTO rides (
        id, pickup, destination, passengers, requested_at, status,
        pickup_latitude, pickup_longitude, meter_fare_minor
      ) VALUES (
        @id, 'OUTBOX-TEST-PICKUP', 'OUTBOX-TEST-DESTINATION',
        1, @now, 'pending', 42.654321, 23.345678, 987654321
      )
    '''),
    parameters: {'id': rideId, 'now': now},
  );

  final offeredAt = now.subtract(const Duration(seconds: 1));
  await session.execute(
    Sql.named('''
      INSERT INTO ride_offers (
        id, ride_id, driver_id, vehicle_id, source,
        eta_seconds, distance_meters, dispatch_round, bonus_minor,
        offered_at, expires_at, status, resolved_at, displayed_at
      ) VALUES (
        @id, @rideId, @driverId, @vehicleId, 'automatic',
        120, 1000, 1, 0,
        @offeredAt, @expiresAt, 'rejected', @resolvedAt, @displayedAt
      )
    '''),
    parameters: {
      'id': offerId,
      'rideId': rideId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'offeredAt': offeredAt,
      'expiresAt': now.add(const Duration(seconds: 15)),
      'resolvedAt': now,
      'displayedAt': offeredAt,
    },
  );
}

class _RollbackAfterAssertions implements Exception {
  const _RollbackAfterAssertions();
}

void main() {
  test('PostgreSQL outbox repository persists, owner-filters, and classifies retries', () async {
    final database = await _connectToCity6Test();
    Map<String, String>? before;
    Object? transactionFailure;
    StackTrace? transactionFailureStack;
    var rollbackSentinelReached = false;

    try {
      before = await _tableFingerprints(database);
      try {
        await database.runTx((transaction) async {
          final columns = await transaction.execute('''
              SELECT column_name
              FROM information_schema.columns
              WHERE table_schema = 'public'
                AND table_name = 'driver_offer_action_outbox'
            ''');
          expect(columns, hasLength(18));

          final now = DateTime.now().toUtc();
          final createdAt = now.subtract(const Duration(milliseconds: 1));
          final ids = const Uuid();
          final driverId = ids.v4();
          final otherDriverId = ids.v4();
          final vehicleId = ids.v4();
          final rideId = ids.v4();
          final secondRideId = ids.v4();
          final offerId = ids.v4();
          final secondOfferId = ids.v4();
          final actionId = ids.v4();

          await _insertDriver(transaction, id: driverId, now: now);
          await _insertDriver(transaction, id: otherDriverId, now: now);
          await _insertVehicle(transaction, id: vehicleId);
          await _insertRideAndOffer(
            transaction,
            rideId: rideId,
            offerId: offerId,
            driverId: driverId,
            vehicleId: vehicleId,
            now: now,
          );
          await _insertRideAndOffer(
            transaction,
            rideId: secondRideId,
            offerId: secondOfferId,
            driverId: driverId,
            vehicleId: vehicleId,
            now: now,
          );

          final repository = PostgresDriverOfferActionOutboxRepository();
          final action = DriverOfferActionOutboxRecord(
            actionId: actionId,
            offerId: offerId,
            driverId: driverId,
            action: DriverOfferAction.reject,
            idempotencyKey: 'integration-${ids.v4()}',
            requestHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            policyOutcome: 'penalty_exempt',
            redispatchStatus: DriverOfferRedispatchStatus.queued,
            attemptCount: 0,
            availableAt: now,
            leaseToken: null,
            leaseUntil: null,
            lastErrorCode: null,
            redispatchResult: {'result': 'queued'},
            createdAt: createdAt,
            settledAt: now,
            updatedAt: now,
            redispatchCompletedAt: null,
          );

          final insertResult = await repository.insert(
            transaction: transaction,
            record: action,
          );
          expect(insertResult, isA<DriverOfferActionInserted>());

          final loaded = await repository.findForDriver(
            session: transaction,
            offerId: offerId,
            driverId: driverId,
          );
          expect(loaded, isNotNull);
          expect(loaded!.requestHash, action.requestHash);
          expect(loaded.idempotencyKey, action.idempotencyKey);
          expect(loaded.redispatchResult, {'result': 'queued'});
          expect(loaded.createdAt, createdAt);

          final foreignLookup = await repository.findForDriver(
            session: transaction,
            offerId: offerId,
            driverId: otherDriverId,
          );
          expect(foreignLookup, isNull);

          final keyLookup = await repository.findByDriverAndIdempotencyKey(
            session: transaction,
            driverId: driverId,
            idempotencyKey: action.idempotencyKey!,
          );
          expect(keyLookup?.offerId, offerId);

          final repeated = await repository.insert(
            transaction: transaction,
            record: action,
          );
          expect(repeated, isA<DriverOfferActionAlreadyExists>());

          final keyConflict = await repository.insert(
            transaction: transaction,
            record: DriverOfferActionOutboxRecord(
              actionId: ids.v4(),
              offerId: secondOfferId,
              driverId: driverId,
              action: DriverOfferAction.reject,
              idempotencyKey: action.idempotencyKey,
              requestHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              policyOutcome: 'penalty_exempt',
              redispatchStatus: DriverOfferRedispatchStatus.queued,
              attemptCount: 0,
              availableAt: now,
              leaseToken: null,
              leaseUntil: null,
              lastErrorCode: null,
              redispatchResult: null,
              createdAt: createdAt,
              settledAt: now,
              updatedAt: now,
              redispatchCompletedAt: null,
            ),
          );
          expect(keyConflict, isA<DriverOfferActionIdempotencyConflict>());

          throw const _RollbackAfterAssertions();
        });
      } on _RollbackAfterAssertions {
        rollbackSentinelReached = true;
      } catch (error, stackTrace) {
        transactionFailure = error;
        transactionFailureStack = stackTrace;
      }

      expect(rollbackSentinelReached, isTrue);
      expect(await _tableFingerprints(database), before);
      if (transactionFailure != null) {
        Error.throwWithStackTrace(transactionFailure, transactionFailureStack!);
      }
    } finally {
      await database.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

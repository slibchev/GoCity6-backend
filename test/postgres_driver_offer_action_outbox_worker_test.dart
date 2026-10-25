import 'dart:io';

import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_worker_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<Connection> _connect() async {
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  if (password == null || password.isEmpty) {
    fail('CITY6_TEST_DB_PASSWORD is required.');
  }
  final connection = await Connection.open(
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
    final result = await connection.execute('''
      SELECT current_database() AS database_name,
             current_user AS role_name,
             current_schema() AS schema_name
    ''');
    expect(result.single.toColumnMap(), {
      'database_name': 'city6_test',
      'role_name': 'city6_app',
      'schema_name': 'public',
    });
    return connection;
  } catch (_) {
    await connection.close();
    rethrow;
  }
}

void main() {
  test('two PostgreSQL workers cannot claim the same outbox job', () async {
    final firstConnection = await _connect();
    Connection? secondConnection;
    final fixture = _FixtureIds.newIds();
    try {
      secondConnection = await _connect();
      await _createFixture(firstConnection, fixture);

      final firstRepository = PostgresDriverOfferActionOutboxWorkerRepository(
        database: firstConnection,
      );
      final secondRepository = PostgresDriverOfferActionOutboxWorkerRepository(
        database: secondConnection,
      );
      final claims = await Future.wait([
        firstRepository.claimNext(
          leaseToken: const Uuid().v4(),
          leaseDuration: const Duration(seconds: 30),
          maxAttempts: 5,
        ),
        secondRepository.claimNext(
          leaseToken: const Uuid().v4(),
          leaseDuration: const Duration(seconds: 30),
          maxAttempts: 5,
        ),
      ]);

      final claimed = claims
          .whereType<DriverOfferActionOutboxRecord>()
          .toList();
      expect(claimed, hasLength(1));
      expect(claimed.single.actionId, fixture.actionId);
      expect(
        claimed.single.redispatchStatus,
        DriverOfferRedispatchStatus.leased,
      );
      expect(claimed.single.attemptCount, 1);

      final persisted = await firstConnection.execute(
        Sql.named('''
          SELECT redispatch_status, lease_token, attempt_count
          FROM driver_offer_action_outbox
          WHERE action_id = @actionId
        '''),
        parameters: {'actionId': fixture.actionId},
      );
      final row = persisted.single.toColumnMap();
      expect(row['redispatch_status'], 'leased');
      expect(row['lease_token'], claimed.single.leaseToken);
      expect(row['attempt_count'], 1);
    } finally {
      try {
        await _deleteFixture(firstConnection, fixture);
      } finally {
        await secondConnection?.close();
        await firstConnection.close();
      }
    }
  });
}

final class _FixtureIds {
  const _FixtureIds({
    required this.driverId,
    required this.vehicleId,
    required this.rideId,
    required this.offerId,
    required this.actionId,
  });

  factory _FixtureIds.newIds() {
    const ids = Uuid();
    return _FixtureIds(
      driverId: ids.v4(),
      vehicleId: ids.v4(),
      rideId: ids.v4(),
      offerId: ids.v4(),
      actionId: ids.v4(),
    );
  }

  final String driverId;
  final String vehicleId;
  final String rideId;
  final String offerId;
  final String actionId;
}

Future<void> _createFixture(Connection database, _FixtureIds fixture) async {
  final now = DateTime.now().toUtc();
  await database.runTx((transaction) async {
    await transaction.execute(
      Sql.named('''
        INSERT INTO drivers (
          id, username, password_hash, first_name, last_name, phone, created_at
        ) VALUES (
          @id, @username, 'outbox-worker-integration-hash',
          'Outbox-Worker-Test', 'Driver', @phone, @now
        )
      '''),
      parameters: {
        'id': fixture.driverId,
        'username': 'outbox-worker-${fixture.driverId}',
        'phone': 'outbox-worker-${fixture.driverId}',
        'now': now,
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO vehicles (id, plate_number, created_at)
        VALUES (@id, @plate, @now)
      '''),
      parameters: {
        'id': fixture.vehicleId,
        'plate': 'OW-${fixture.driverId.replaceAll('-', '').substring(0, 12)}',
        'now': now,
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO rides (
          id, pickup, destination, passengers, requested_at, status,
          assigned_driver_id, assigned_vehicle_id, dispatch_round,
          driver_bonus_minor, bonus_decision
        ) VALUES (
          @id, 'OUTBOX-WORKER-TEST-PICKUP', 'OUTBOX-WORKER-TEST-DESTINATION',
          1, @now, 'pending', NULL, NULL, 1, 0, 'not_offered'
        )
      '''),
      parameters: {'id': fixture.rideId, 'now': now},
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO ride_offers (
          id, ride_id, driver_id, vehicle_id, source,
          eta_seconds, distance_meters, dispatch_round, bonus_minor,
          offered_at, expires_at, status, resolved_at, displayed_at
        ) VALUES (
          @id, @rideId, @driverId, @vehicleId, 'automatic',
          60, 500, 1, 0, @now, @expiresAt, 'rejected', @now, @now
        )
      '''),
      parameters: {
        'id': fixture.offerId,
        'rideId': fixture.rideId,
        'driverId': fixture.driverId,
        'vehicleId': fixture.vehicleId,
        'now': now,
        'expiresAt': now.add(const Duration(seconds: 15)),
      },
    );
    final action = DriverOfferActionOutboxRecord(
      actionId: fixture.actionId,
      offerId: fixture.offerId,
      driverId: fixture.driverId,
      action: DriverOfferAction.reject,
      idempotencyKey: null,
      requestHash: List.filled(64, 'b').join(),
      policyOutcome: 'not_eligible',
      redispatchStatus: DriverOfferRedispatchStatus.queued,
      attemptCount: 0,
      availableAt: now.subtract(const Duration(seconds: 1)),
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: null,
      redispatchResult: null,
      createdAt: now,
      settledAt: now,
      updatedAt: now,
      redispatchCompletedAt: null,
    );
    final insert = await PostgresDriverOfferActionOutboxRepository().insert(
      transaction: transaction,
      record: action,
    );
    expect(insert, isA<DriverOfferActionInserted>());
  });
}

Future<void> _deleteFixture(Connection database, _FixtureIds fixture) async {
  await database.runTx((transaction) async {
    await transaction.execute(
      Sql.named('DELETE FROM driver_offer_action_outbox WHERE action_id = @id'),
      parameters: {'id': fixture.actionId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM ride_offers WHERE id = @id'),
      parameters: {'id': fixture.offerId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM rides WHERE id = @id'),
      parameters: {'id': fixture.rideId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM vehicles WHERE id = @id'),
      parameters: {'id': fixture.vehicleId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM drivers WHERE id = @id'),
      parameters: {'id': fixture.driverId},
    );
  });
}

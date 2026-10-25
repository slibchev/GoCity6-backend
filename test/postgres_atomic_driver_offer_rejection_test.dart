import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_driver_offer_rejection_service.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_driver_offer_rejection_transaction_runner.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<Connection> _connectToCity6Test() async {
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
    final identity = await connection.execute('''
      SELECT current_database() AS database_name,
             current_user AS role_name,
             current_schema() AS schema_name
    ''');
    expect(identity.single.toColumnMap(), {
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

Future<Map<String, String>> _fingerprints(Session session) async {
  const tables = [
    'drivers',
    'vehicles',
    'rides',
    'ride_offers',
    'driver_shifts',
    'driver_queue_states',
    'driver_dispatch_states',
    'driver_offer_action_outbox',
  ];
  final result = <String, String>{};
  for (final table in tables) {
    final rows = await session.execute(
      Sql('''
      SELECT count(*)::text AS row_count,
             md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10)
               ORDER BY to_jsonb(t)::text), '')) AS fingerprint
      FROM public.$table AS t
    '''),
    );
    final row = rows.single.toColumnMap();
    result[table] = '${row['row_count']}:${row['fingerprint']}';
  }
  return result;
}

final class _FixtureIds {
  const _FixtureIds({required this.driverId, required this.offerId});

  final String driverId;
  final String offerId;
}

Future<_FixtureIds> _insertFixture(
  Session session, {
  required DateTime now,
}) async {
  final ids = const Uuid();
  final driverId = ids.v4();
  final vehicleId = ids.v4();
  final shiftId = ids.v4();
  final rideId = ids.v4();
  final offerId = ids.v4();

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
      'id': driverId,
      'username': 'atomic-reject-$driverId',
      'phone': 'atomic-reject-$driverId',
      'now': now,
    },
  );
  await session.execute(
    Sql.named('''
      INSERT INTO vehicles (id, plate_number, created_at)
      VALUES (@id, @plate, @now)
    '''),
    parameters: {
      'id': vehicleId,
      'plate': 'AR-${driverId.replaceAll('-', '').substring(0, 12)}',
      'now': now,
    },
  );
  await session.execute(
    Sql.named('''
      INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
      VALUES (@id, @driverId, @vehicleId, @now)
    '''),
    parameters: {
      'id': shiftId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'now': now.subtract(const Duration(hours: 1)),
    },
  );
  await session.execute(
    Sql.named('''
      INSERT INTO driver_queue_states (
        shift_id, availability, queue_priority_since, has_pending_offer
      ) VALUES (@shiftId, 'available', @now, TRUE)
    '''),
    parameters: {'shiftId': shiftId, 'now': now},
  );
  await session.execute(
    Sql.named('''
      INSERT INTO driver_dispatch_states (
        driver_id, consecutive_rejects, penalty_level,
        dispatch_blocked_until, penalty_reset_eligible_at,
        requires_completed_ride_after_penalty
      ) VALUES (@driverId, 2, 0, NULL, NULL, FALSE)
    '''),
    parameters: {'driverId': driverId},
  );
  await session.execute(
    Sql.named('''
      INSERT INTO rides (
        id, pickup, destination, passengers, requested_at, status,
        assigned_driver_id, assigned_vehicle_id, dispatch_round,
        driver_bonus_minor, bonus_decision
      ) VALUES (
        @id, 'TEST-PICKUP', 'TEST-DESTINATION', 1,
        @requestedAt, 'pending', NULL, NULL, 1, 0, 'not_offered'
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': now.subtract(const Duration(minutes: 2)),
    },
  );
  await session.execute(
    Sql.named('''
      INSERT INTO ride_offers (
        id, ride_id, driver_id, vehicle_id, source,
        eta_seconds, distance_meters, dispatch_round, bonus_minor,
        offered_at, expires_at, status, resolved_at, displayed_at
      ) VALUES (
        @id, @rideId, @driverId, @vehicleId, 'automatic',
        60, 500, 1, 0, @offeredAt, @expiresAt, 'pending', NULL, @offeredAt
      )
    '''),
    parameters: {
      'id': offerId,
      'rideId': rideId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'offeredAt': now.subtract(const Duration(seconds: 1)),
      'expiresAt': now.add(const Duration(seconds: 15)),
    },
  );
  return _FixtureIds(driverId: driverId, offerId: offerId);
}

class _RollbackAfterAssertions implements Exception {
  const _RollbackAfterAssertions();
}

void main() {
  test('atomic reject applies policy, queue, offer, and outbox in one rollback-verified transaction', () async {
    final database = await _connectToCity6Test();
    try {
      final before = await _fingerprints(database);
      expect(
        before['driver_offer_action_outbox']?.split(':').first,
        '0',
        reason: 'The isolated outbox fixture must start empty.',
      );

      var rollbackReached = false;
      try {
        await database.runTx((transaction) async {
          final now = DateTime.now().toUtc();
          final fixture = await _insertFixture(transaction, now: now);

          final runner = PostgresAtomicDriverOfferRejectionTransactionRunner(
            database: database,
            dispatchStateRepository: PostgresDriverDispatchStateRepository(
              database: database,
            ),
            outboxRepository: PostgresDriverOfferActionOutboxRepository(),
          );
          // The test injects the already-open TxSession into the exact same
          // transaction adapter used by the production runner.
          final service = AtomicDriverOfferRejectionService(
            transactionRunner: runner,
            clock: () => now,
            actionIdFactory: () => const Uuid().v4(),
          );
          final result = await service.rejectInTransaction(
            transaction: PostgresDriverOfferRejectionTransaction(
              session: transaction,
              dispatchStateRepository: PostgresDriverDispatchStateRepository(
                database: database,
              ),
              outboxRepository: PostgresDriverOfferActionOutboxRepository(),
            ),
            driverId: fixture.driverId,
            offerId: fixture.offerId,
            idempotencyKey: 'atomic-reject-integration-${const Uuid().v4()}',
          );
          expect(result, isA<AtomicDriverOfferRejectionApplied>());
          final applied = result as AtomicDriverOfferRejectionApplied;
          expect(
            applied.policyOutcome,
            DriverOfferRejectionPolicyOutcome.standardEligible,
          );
          expect(applied.dispatchState?.consecutiveRejects, 0);
          expect(applied.dispatchState?.penaltyLevel, 1);
          expect(
            applied.outboxRecord.redispatchStatus,
            DriverOfferRedispatchStatus.queued,
          );
          expect(
            applied.outboxRecord.settledAt.isBefore(
              applied.outboxRecord.createdAt,
            ),
            isFalse,
          );

          final rows = await transaction.execute(
            Sql.named('''
              SELECT
                o.status AS offer_status,
                q.has_pending_offer,
                s.penalty_level,
                s.consecutive_rejects,
                s.requires_completed_ride_after_penalty,
                x.action,
                x.policy_outcome,
                x.redispatch_status
              FROM ride_offers o
              JOIN driver_shifts d ON d.driver_id = o.driver_id AND d.ended_at IS NULL
              JOIN driver_queue_states q ON q.shift_id = d.id
              JOIN driver_dispatch_states s ON s.driver_id = o.driver_id
              JOIN driver_offer_action_outbox x ON x.offer_id = o.id
              WHERE o.id = @offerId
            '''),
            parameters: {'offerId': applied.outboxRecord.offerId},
          );
          final row = rows.single.toColumnMap();
          expect(row['offer_status'], 'rejected');
          expect(row['has_pending_offer'], isFalse);
          expect(row['penalty_level'], 1);
          expect(row['consecutive_rejects'], 0);
          expect(row['requires_completed_ride_after_penalty'], isTrue);
          expect(row['action'], 'reject');
          expect(row['policy_outcome'], 'standard_eligible');
          expect(row['redispatch_status'], 'queued');

          throw const _RollbackAfterAssertions();
        });
      } on _RollbackAfterAssertions {
        rollbackReached = true;
      }
      expect(rollbackReached, isTrue);

      final after = await _fingerprints(database);
      expect(after, before);
      expect(after['driver_offer_action_outbox']?.split(':').first, '0');
    } finally {
      await database.close();
    }
  });
}

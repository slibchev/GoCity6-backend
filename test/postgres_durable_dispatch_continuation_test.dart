import 'dart:io';

import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_worker.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_worker_repository.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<Connection> _connect() async {
  final username = Platform.environment['CITY6_TEST_DB_USER'];
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  final port = int.tryParse(Platform.environment['CITY6_TEST_DB_PORT'] ?? '');
  if (username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    fail('Isolated PostgreSQL test credentials are required.');
  }
  if (port != 5433) fail('This test is restricted to isolated port 5433.');
  final connection = await Connection.open(
    Endpoint(
      host: '127.0.0.1',
      port: port!,
      database: 'city6_test',
      username: username,
      password: password,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
  try {
    final rows = await connection.execute('''
      SELECT current_database() AS database_name,
             current_user AS role_name,
             current_schema() AS schema_name,
             host(inet_server_addr()) AS server_address,
             inet_server_port() AS server_port
    ''');
    expect(rows.single.toColumnMap(), {
      'database_name': 'city6_test',
      'role_name': username,
      'schema_name': 'public',
      'server_address': '127.0.0.1',
      'server_port': 5433,
    });
    return connection;
  } catch (_) {
    await connection.close();
    rethrow;
  }
}

const _fingerprintTables = [
  'drivers',
  'vehicles',
  'driver_shifts',
  'driver_queue_states',
  'rides',
  'ride_offers',
  'driver_offer_action_outbox',
];

Future<Map<String, String>> _fingerprints(Session session) async {
  final values = <String, String>{};
  for (final table in _fingerprintTables) {
    final rows = await session.execute('''
      SELECT count(*)::text AS row_count,
             md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10)
               ORDER BY to_jsonb(t)::text), '')) AS row_hash
      FROM public.$table AS t
    ''');
    final row = rows.single.toColumnMap();
    values[table] = '${row['row_count']}:${row['row_hash']}';
  }
  return values;
}

void main() {
  test('initial pending ride and dispatch event commit together and recover', () async {
    final database = await _connect();
    final rideId = const Uuid().v4();
    final actionId = initialDispatchActionId(rideId);
    final before = await _fingerprints(database);
    Object? failure;
    StackTrace? failureStack;
    Object? cleanupFailure;
    StackTrace? cleanupStack;
    try {
      final rides = PostgresRideRequestRepository(database: database);
      await rides.savePendingRideForAutomaticDispatch(
        RideRequest(
          id: rideId,
          pickup: 'Initial dispatch recovery test',
          destination: 'Initial dispatch destination',
          passengers: 1,
          requestedAt: DateTime.now().toUtc(),
          status: RideRequestStatus.pending,
        ),
      );

      final committedRows = await database.execute(
        Sql.named('''
          SELECT ride.status AS ride_status,
                 event.action,
                 event.ride_id,
                 event.redispatch_status
          FROM rides AS ride
          JOIN driver_offer_action_outbox AS event ON event.ride_id = ride.id
          WHERE ride.id = @rideId
        '''),
        parameters: {'rideId': rideId},
      );
      expect(committedRows.single.toColumnMap(), {
        'ride_status': 'pending',
        'action': 'initial_dispatch',
        'ride_id': rideId,
        'redispatch_status': 'queued',
      });
      expect(await rides.recoverPendingDispatchEvents(), 0);

      // Simulate a process stopping after it committed the lease but before
      // dispatch execution. A newly-created worker reclaims the expired lease.
      final repository = PostgresDriverOfferActionOutboxWorkerRepository(
        database: database,
      );
      final firstLease = await repository.claimByActionId(
        actionId: actionId,
        leaseToken: 'initial-crash-before-execution',
        leaseDuration: const Duration(minutes: 1),
        maxAttempts: 5,
      );
      expect(firstLease?.action, DriverOfferAction.initialDispatch);
      await database.execute(
        Sql.named('''
          UPDATE driver_offer_action_outbox
          SET lease_until = clock_timestamp() - INTERVAL '1 second'
          WHERE action_id = @actionId
        '''),
        parameters: {'actionId': actionId},
      );

      final executor = _CountingConfirmedExecutor();
      final worker = _worker(database, executor, 'initial-recovery-worker');
      final recovered = await worker.runAction(actionId);
      expect(
        recovered.disposition,
        DriverOfferActionOutboxWorkerDisposition.completed,
      );
      expect(executor.calls, 1);
      expect(
        (await worker.runAction(actionId)).disposition,
        DriverOfferActionOutboxWorkerDisposition.idle,
      );
      final settled = await database.execute(
        Sql.named('''
          SELECT count(*)::int AS event_count,
                 min(redispatch_status) AS final_status,
                 min(attempt_count) AS attempts
          FROM driver_offer_action_outbox
          WHERE action_id = @actionId
        '''),
        parameters: {'actionId': actionId},
      );
      expect(settled.single.toColumnMap(), {
        'event_count': 1,
        'final_status': 'completed',
        'attempts': 2,
      });
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    try {
      await database.execute(
        Sql.named(
          'DELETE FROM driver_offer_action_outbox WHERE ride_id = @rideId',
        ),
        parameters: {'rideId': rideId},
      );
      await database.execute(
        Sql.named('DELETE FROM rides WHERE id = @rideId'),
        parameters: {'rideId': rideId},
      );
      if (!_same(await _fingerprints(database), before)) {
        throw StateError(
          'Initial-dispatch test cleanup did not restore baseline.',
        );
      }
    } catch (error, stackTrace) {
      cleanupFailure = error;
      cleanupStack = stackTrace;
    } finally {
      await database.close();
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    if (cleanupFailure != null) {
      Error.throwWithStackTrace(cleanupFailure, cleanupStack!);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'offer timeout is durably queued before continuation and is recoverable',
    () async {
      final database = await _connect();
      final fixture = _TimeoutFixture.create();
      final before = await _fingerprints(database);
      Object? failure;
      StackTrace? failureStack;
      Object? cleanupFailure;
      StackTrace? cleanupStack;
      try {
        await _createTimeoutFixture(database, fixture);
        final expired =
            await PostgresAtomicRideOfferRepository(database: database)
                .expirePendingOffer(
                  offerId: fixture.offerId,
                  now: DateTime.now().toUtc(),
                );
        expect(expired.status.name, 'expired');
        final actionId = 'timeout:${fixture.offerId}';
        final queued = await database.execute(
          Sql.named('''
          SELECT offer.status AS offer_status,
                 queue.has_pending_offer,
                 event.action,
                 event.ride_id,
                 event.redispatch_status
          FROM ride_offers AS offer
          JOIN driver_shifts AS shift ON shift.driver_id = offer.driver_id
          JOIN driver_queue_states AS queue ON queue.shift_id = shift.id
          JOIN driver_offer_action_outbox AS event ON event.offer_id = offer.id
          WHERE offer.id = @offerId
        '''),
          parameters: {'offerId': fixture.offerId},
        );
        expect(queued.single.toColumnMap(), {
          'offer_status': 'expired',
          'has_pending_offer': false,
          'action': 'timeout',
          'ride_id': fixture.rideId,
          'redispatch_status': 'queued',
        });

        final repository = PostgresDriverOfferActionOutboxWorkerRepository(
          database: database,
        );
        final firstLease = await repository.claimByActionId(
          actionId: actionId,
          leaseToken: 'timeout-crash-before-execution',
          leaseDuration: const Duration(minutes: 1),
          maxAttempts: 5,
        );
        expect(firstLease?.action, DriverOfferAction.timeout);
        await database.execute(
          Sql.named('''
          UPDATE driver_offer_action_outbox
          SET lease_until = clock_timestamp() - INTERVAL '1 second'
          WHERE action_id = @actionId
        '''),
          parameters: {'actionId': actionId},
        );
        final executor = _CountingConfirmedExecutor();
        final worker = _worker(database, executor, 'timeout-recovery-worker');
        expect(
          (await worker.runAction(actionId)).disposition,
          DriverOfferActionOutboxWorkerDisposition.completed,
        );
        expect(executor.calls, 1);
        final count = await database.execute(
          Sql.named('''
          SELECT count(*)::int AS event_count
          FROM driver_offer_action_outbox
          WHERE offer_id = @offerId AND action = 'timeout'
        '''),
          parameters: {'offerId': fixture.offerId},
        );
        expect(count.single.toColumnMap()['event_count'], 1);
      } catch (error, stackTrace) {
        failure = error;
        failureStack = stackTrace;
      }
      try {
        await _deleteTimeoutFixture(database, fixture);
        if (!_same(await _fingerprints(database), before)) {
          throw StateError('Timeout test cleanup did not restore baseline.');
        }
      } catch (error, stackTrace) {
        cleanupFailure = error;
        cleanupStack = stackTrace;
      } finally {
        await database.close();
      }
      if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
      if (cleanupFailure != null) {
        Error.throwWithStackTrace(cleanupFailure, cleanupStack!);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

DriverOfferActionOutboxWorker _worker(
  Connection database,
  DriverOfferRedispatchExecutor executor,
  String leaseToken,
) => DriverOfferActionOutboxWorker(
  repository: PostgresDriverOfferActionOutboxWorkerRepository(
    database: database,
  ),
  executor: executor,
  leaseDuration: const Duration(minutes: 1),
  maxAttempts: 5,
  leaseTokenFactory: () => leaseToken,
);

final class _CountingConfirmedExecutor
    implements DriverOfferRedispatchExecutor {
  int calls = 0;

  @override
  Future<DriverOfferRedispatchExecutionResult> execute(
    DriverOfferActionOutboxRecord action,
  ) async {
    calls++;
    expect(
      action.action,
      anyOf(DriverOfferAction.timeout, DriverOfferAction.initialDispatch),
    );
    return const DriverOfferRedispatchConfirmed();
  }
}

final class _TimeoutFixture {
  _TimeoutFixture._({
    required this.driverId,
    required this.vehicleId,
    required this.shiftId,
    required this.rideId,
    required this.offerId,
  });

  factory _TimeoutFixture.create() {
    const uuid = Uuid();
    return _TimeoutFixture._(
      driverId: uuid.v4(),
      vehicleId: uuid.v4(),
      shiftId: uuid.v4(),
      rideId: uuid.v4(),
      offerId: uuid.v4(),
    );
  }

  final String driverId;
  final String vehicleId;
  final String shiftId;
  final String rideId;
  final String offerId;
}

Future<void> _createTimeoutFixture(
  Connection database,
  _TimeoutFixture fixture,
) async {
  final now = DateTime.now().toUtc();
  await database.runTx((transaction) async {
    await transaction.execute(
      Sql.named('''
        INSERT INTO drivers (
          id, username, password_hash, first_name, last_name, phone,
          is_active, created_at
        ) VALUES (
          @id, @username, 'integration-test-hash',
          'Outbox', 'Timeout', @phone, TRUE, @now
        )
      '''),
      parameters: {
        'id': fixture.driverId,
        'username': 'outbox-timeout-${fixture.driverId}',
        'phone': 'outbox-timeout-${fixture.driverId}',
        'now': now,
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO vehicles (id, plate_number, is_active, created_at)
        VALUES (@id, @plate, TRUE, @now)
      '''),
      parameters: {
        'id': fixture.vehicleId,
        'plate': 'OT-${fixture.vehicleId.replaceAll('-', '').substring(0, 8)}',
        'now': now,
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
        VALUES (@id, @driverId, @vehicleId, @startedAt)
      '''),
      parameters: {
        'id': fixture.shiftId,
        'driverId': fixture.driverId,
        'vehicleId': fixture.vehicleId,
        'startedAt': now.subtract(const Duration(hours: 1)),
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO driver_queue_states (
          shift_id, availability, queue_priority_since, break_started_at,
          has_pending_offer
        ) VALUES (@shiftId, 'available', @priority, NULL, TRUE)
      '''),
      parameters: {
        'shiftId': fixture.shiftId,
        'priority': now.subtract(const Duration(minutes: 2)),
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO rides (
          id, pickup, destination, passengers, requested_at, status,
          assigned_driver_id, assigned_vehicle_id
        ) VALUES (
          @id, 'Timeout recovery test', 'Timeout recovery destination',
          1, @requestedAt, 'pending', NULL, NULL
        )
      '''),
      parameters: {
        'id': fixture.rideId,
        'requestedAt': now.subtract(const Duration(minutes: 2)),
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO ride_offers (
          id, ride_id, driver_id, vehicle_id, source,
          eta_seconds, distance_meters, dispatch_round, bonus_minor,
          offered_at, expires_at, status, resolved_at, displayed_at
        ) VALUES (
          @id, @rideId, @driverId, @vehicleId, 'automatic',
          45, 300, 1, 0, @offeredAt, @expiresAt, 'pending', NULL, @offeredAt
        )
      '''),
      parameters: {
        'id': fixture.offerId,
        'rideId': fixture.rideId,
        'driverId': fixture.driverId,
        'vehicleId': fixture.vehicleId,
        'offeredAt': now.subtract(const Duration(minutes: 2)),
        'expiresAt': now.subtract(const Duration(minutes: 1)),
      },
    );
  });
}

Future<void> _deleteTimeoutFixture(
  Connection database,
  _TimeoutFixture fixture,
) async {
  await database.runTx((transaction) async {
    await transaction.execute(
      Sql.named(
        'DELETE FROM driver_offer_action_outbox WHERE ride_id = @rideId',
      ),
      parameters: {'rideId': fixture.rideId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM ride_offers WHERE ride_id = @rideId'),
      parameters: {'rideId': fixture.rideId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM rides WHERE id = @rideId'),
      parameters: {'rideId': fixture.rideId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_queue_states WHERE shift_id = @shiftId'),
      parameters: {'shiftId': fixture.shiftId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_shifts WHERE id = @shiftId'),
      parameters: {'shiftId': fixture.shiftId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM drivers WHERE id = @driverId'),
      parameters: {'driverId': fixture.driverId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM vehicles WHERE id = @vehicleId'),
      parameters: {'vehicleId': fixture.vehicleId},
    );
  });
}

bool _same(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in right.entries) {
    if (left[entry.key] != entry.value) return false;
  }
  return true;
}

import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_driver_offer_rejection_service.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_redispatch_executor.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_redispatch_service.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_worker.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/idempotent_automatic_redispatch_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_driver_offer_rejection_transaction_runner.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_worker_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<T> _traceStage<T>(String stage, Future<T> Function() action) async {
  stderr.writeln('[atomic-reject-e2e] $stage.start');
  final result = await action();
  stderr.writeln('[atomic-reject-e2e] $stage.complete');
  return result;
}

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
    final identity = await database.execute('''
      SELECT current_database() AS database_name,
             current_user AS role_name,
             current_schema() AS schema_name,
             host(inet_server_addr()) AS server_address,
             inet_server_port() AS server_port
    ''');
    expect(identity.single.toColumnMap(), {
      'database_name': 'city6_test',
      'role_name': 'city6_app',
      'schema_name': 'public',
      'server_address': anyOf('127.0.0.1', '::1'),
      'server_port': 5432,
    });
    final requiredObjects = await database.execute('''
      SELECT
        to_regclass('public.driver_offer_action_outbox') IS NOT NULL
          AS has_outbox,
        EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = 'ride_offers'
            AND column_name = 'redispatch_action_id'
        ) AS has_redispatch_link
    ''');
    expect(requiredObjects.single.toColumnMap(), {
      'has_outbox': true,
      'has_redispatch_link': true,
    });
    return database;
  } catch (_) {
    await database.close();
    rethrow;
  }
}

const _fingerprintedTables = [
  'drivers',
  'vehicles',
  'rides',
  'ride_offers',
  'driver_shifts',
  'driver_queue_states',
  'driver_dispatch_states',
  'driver_offer_action_outbox',
];

Future<Map<String, String>> _fingerprints(Session session) async {
  final result = <String, String>{};
  for (final table in _fingerprintedTables) {
    final rows = await session.execute('''
      SELECT count(*)::text AS row_count,
             md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10)
               ORDER BY to_jsonb(t)::text), '')) AS fingerprint
      FROM public.$table AS t
    ''');
    final row = rows.single.toColumnMap();
    result[table] = '${row['row_count']}:${row['fingerprint']}';
  }
  return result;
}

final class _FixtureIds {
  _FixtureIds._({
    required this.driverAId,
    required this.driverBId,
    required this.vehicleAId,
    required this.vehicleBId,
    required this.shiftAId,
    required this.shiftBId,
    required this.rideId,
    required this.originalOfferId,
    required this.actionId,
  });

  factory _FixtureIds.create() {
    const uuid = Uuid();
    return _FixtureIds._(
      driverAId: uuid.v4(),
      driverBId: uuid.v4(),
      vehicleAId: uuid.v4(),
      vehicleBId: uuid.v4(),
      shiftAId: uuid.v4(),
      shiftBId: uuid.v4(),
      rideId: uuid.v4(),
      originalOfferId: uuid.v4(),
      actionId: uuid.v4(),
    );
  }

  final String driverAId;
  final String driverBId;
  final String vehicleAId;
  final String vehicleBId;
  final String shiftAId;
  final String shiftBId;
  final String rideId;
  final String originalOfferId;
  final String actionId;
}

void main() {
  test('committed atomic reject flows through outbox redispatch and recovers safely', () async {
    final database = await _connectToCity6Test();
    final fixtures = List<_FixtureIds>.generate(3, (_) => _FixtureIds.create());
    final before = await _fingerprints(database);
    final initialOutboxCount = int.parse(
      before['driver_offer_action_outbox']!.split(':').first,
    );
    Object? testFailure;
    StackTrace? testStack;
    Object? cleanupFailure;
    StackTrace? cleanupStack;
    try {
      expect(
        initialOutboxCount,
        0,
        reason: 'The isolated city6_test outbox must be empty before fixtures.',
      );
      await _verifyNoReadyJobs(database);
      await _createFixture(database, fixtures[0]);
      final firstReject = await _reject(database, fixtures[0]);
      expect(firstReject, isA<AtomicDriverOfferRejectionApplied>());
      final applied = firstReject as AtomicDriverOfferRejectionApplied;
      expect(applied.outboxRecord.actionId, fixtures[0].actionId);
      expect(
        applied.policyOutcome,
        DriverOfferRejectionPolicyOutcome.standardEligible,
      );

      // reject() returned after PostgresAtomicDriverOfferRejectionTransactionRunner
      // committed. Read through a separate connection to prove visibility.
      final observer = await _connectToCity6Test();
      try {
        final committed = await _readActionState(observer, fixtures[0]);
        expect(committed['offer_status'], 'rejected');
        expect(committed['queue_pending'], false);
        expect(committed['consecutive_rejects'], 0);
        expect(committed['penalty_level'], 1);
        expect(committed['blocked_until'], isA<DateTime>());
        expect(committed['recovery_required'], true);
        expect(committed['action_count'], 1);
        expect(committed['action_id'], fixtures[0].actionId);
        expect(committed['policy_outcome'], 'standard_eligible');
        expect(committed['redispatch_status'], 'queued');
      } finally {
        await observer.close();
      }

      await _verifyOnlyReadyJob(database, fixtures[0].actionId);
      final worker = _worker(database, leaseToken: 'e2e-first-lease');
      final workerResult = await _traceStage('worker.runOnce', worker.runOnce);
      expect(
        workerResult.disposition,
        DriverOfferActionOutboxWorkerDisposition.completed,
      );
      expect(workerResult.actionId, fixtures[0].actionId);
      final firstPostDispatch = await _readRedispatchState(
        database,
        fixtures[0],
      );
      expect(firstPostDispatch['causal_offer_count'], 1);
      expect(firstPostDispatch['causal_offer_driver'], fixtures[0].driverBId);
      expect(firstPostDispatch['causal_offer_source'], 'automatic');
      expect(firstPostDispatch['causal_offer_status'], 'pending');
      expect(firstPostDispatch['candidate_queue_pending'], true);
      expect(firstPostDispatch['outbox_status'], 'completed');
      expect(firstPostDispatch['attempt_count'], 1);
      expect(firstPostDispatch['lease_token'], isNull);
      expect(firstPostDispatch['completed_at'], isA<DateTime>());

      final repeatedReject = await _reject(database, fixtures[0]);
      expect(repeatedReject, isA<AtomicDriverOfferRejectionAlreadyRecorded>());
      final afterRepeatedReject = await _readRedispatchState(
        database,
        fixtures[0],
      );
      expect(afterRepeatedReject['causal_offer_count'], 1);
      expect(afterRepeatedReject['attempt_count'], 1);
      expect(afterRepeatedReject['penalty_level'], 1);
      expect(afterRepeatedReject['consecutive_rejects'], 0);
      final repeatedWorker = await _worker(
        database,
        leaseToken: 'e2e-idle-lease',
      ).runOnce();
      expect(
        repeatedWorker.disposition,
        DriverOfferActionOutboxWorkerDisposition.idle,
      );

      // Stale lease: after B reclaims A's expired job, A cannot create an
      // offer or finalize the current lease.
      await _createFixture(database, fixtures[1]);
      expect(
        await _reject(database, fixtures[1]),
        isA<AtomicDriverOfferRejectionApplied>(),
      );
      final workerRepository = PostgresDriverOfferActionOutboxWorkerRepository(
        database: database,
      );
      final staleLease = await workerRepository.claimNext(
        leaseToken: 'e2e-stale-worker-token',
        leaseDuration: const Duration(minutes: 1),
        maxAttempts: 5,
      );
      expect(staleLease?.actionId, fixtures[1].actionId);
      await database.execute(
        Sql.named('''
            UPDATE driver_offer_action_outbox
            SET lease_until = clock_timestamp() - INTERVAL '1 second'
            WHERE action_id = @actionId
          '''),
        parameters: {'actionId': fixtures[1].actionId},
      );
      final currentLease = await workerRepository.claimNext(
        leaseToken: 'e2e-current-worker-token',
        leaseDuration: const Duration(minutes: 1),
        maxAttempts: 5,
      );
      expect(currentLease?.actionId, fixtures[1].actionId);
      expect(currentLease?.attemptCount, 2);

      final executor = _executor(database);
      await expectLater(
        executor.execute(staleLease!),
        throwsA(
          isA<AutomaticRedispatchConflictException>().having(
            (error) => error.conflict,
            'conflict',
            AutomaticRedispatchConflict.leaseLost,
          ),
        ),
      );
      expect(
        await PostgresAtomicRideOfferRepository(database: database)
            .findOfferByRedispatchActionId(fixtures[1].actionId),
        isNull,
      );
      expect(
        await workerRepository.markCompleted(
          actionId: fixtures[1].actionId,
          leaseToken: staleLease.leaseToken!,
        ),
        false,
      );
      expect(
        await executor.execute(currentLease!),
        isA<DriverOfferRedispatchConfirmed>(),
      );
      expect(
        await workerRepository.markCompleted(
          actionId: fixtures[1].actionId,
          leaseToken: currentLease.leaseToken!,
        ),
        true,
      );
      final stalePostflight = await _readRedispatchState(database, fixtures[1]);
      expect(stalePostflight['causal_offer_count'], 1);
      expect(stalePostflight['outbox_status'], 'completed');
      expect(stalePostflight['attempt_count'], 2);
      expect(stalePostflight['penalty_level'], 1);

      // Crash boundary: A commits the causal offer, then is interrupted
      // before markCompleted. B reclaims the same action and observes the
      // durable redispatch_action_id instead of creating another offer.
      await _createFixture(database, fixtures[2]);
      expect(
        await _reject(database, fixtures[2]),
        isA<AtomicDriverOfferRejectionApplied>(),
      );
      final outboxWorkerRepository =
          PostgresDriverOfferActionOutboxWorkerRepository(database: database);
      final workerAAction = await outboxWorkerRepository.claimNext(
        leaseToken: 'e2e-crash-worker-a-token',
        leaseDuration: const Duration(minutes: 1),
        maxAttempts: 5,
      );
      expect(workerAAction?.actionId, fixtures[2].actionId);
      expect(
        await _executor(database).execute(workerAAction!),
        isA<DriverOfferRedispatchConfirmed>(),
      );
      final persistedAfterCrashBoundary = await _readRedispatchState(
        database,
        fixtures[2],
      );
      expect(persistedAfterCrashBoundary['causal_offer_count'], 1);
      expect(persistedAfterCrashBoundary['outbox_status'], 'leased');
      expect(persistedAfterCrashBoundary['attempt_count'], 1);
      await database.execute(
        Sql.named('''
            UPDATE driver_offer_action_outbox
            SET lease_until = clock_timestamp() - INTERVAL '1 second'
            WHERE action_id = @actionId
          '''),
        parameters: {'actionId': fixtures[2].actionId},
      );
      final workerBResult = await _worker(
        database,
        leaseToken: 'e2e-crash-worker-b-token',
      ).runOnce();
      expect(
        workerBResult.disposition,
        DriverOfferActionOutboxWorkerDisposition.completed,
      );
      expect(workerBResult.actionId, fixtures[2].actionId);
      final afterCrashRecovery = await _readRedispatchState(
        database,
        fixtures[2],
      );
      expect(afterCrashRecovery['causal_offer_count'], 1);
      expect(afterCrashRecovery['causal_offer_driver'], fixtures[2].driverBId);
      expect(afterCrashRecovery['outbox_status'], 'completed');
      expect(afterCrashRecovery['attempt_count'], 2);
      expect(afterCrashRecovery['penalty_level'], 1);
      expect(afterCrashRecovery['consecutive_rejects'], 0);
      expect(
        await outboxWorkerRepository.markCompleted(
          actionId: fixtures[2].actionId,
          leaseToken: workerAAction.leaseToken!,
        ),
        false,
      );
    } catch (error, stackTrace) {
      testFailure = error;
      testStack = stackTrace;
    }

    try {
      for (final fixture in fixtures.reversed) {
        await _deleteFixture(database, fixture);
      }
    } catch (error, stackTrace) {
      cleanupFailure = error;
      cleanupStack = stackTrace;
    }
    try {
      final after = await _fingerprints(database);
      if (after.length != before.length ||
          !_sameFingerprintMap(after, before)) {
        throw StateError(
          'PostgreSQL fixture cleanup did not restore the baseline.',
        );
      }
    } catch (error, stackTrace) {
      cleanupFailure ??= error;
      cleanupStack ??= stackTrace;
    } finally {
      await database.close();
    }

    if (testFailure != null) {
      Error.throwWithStackTrace(testFailure, testStack!);
    }
    if (cleanupFailure != null) {
      Error.throwWithStackTrace(cleanupFailure, cleanupStack!);
    }
  });
}

bool _sameFingerprintMap(Map<String, String> left, Map<String, String> right) {
  for (final table in _fingerprintedTables) {
    if (left[table] != right[table]) return false;
  }
  return true;
}

Future<void> _verifyNoReadyJobs(Session session) async {
  final result = await session.execute('''
    SELECT count(*)::int
    FROM driver_offer_action_outbox
    WHERE action = 'reject'
      AND (
        (redispatch_status IN ('queued', 'retryable')
          AND available_at <= clock_timestamp())
        OR (redispatch_status = 'leased'
          AND lease_until <= clock_timestamp())
      )
  ''');
  expect(result.single[0], 0, reason: 'No other ready job may be claimed.');
}

Future<void> _verifyOnlyReadyJob(Session session, String actionId) async {
  final result = await session.execute('''
    SELECT action_id
    FROM driver_offer_action_outbox
    WHERE action = 'reject'
      AND (
        (redispatch_status IN ('queued', 'retryable')
          AND available_at <= clock_timestamp())
        OR (redispatch_status = 'leased'
          AND lease_until <= clock_timestamp())
      )
    ORDER BY action_id
  ''');
  expect(result.map((row) => row[0]), [actionId]);
}

Future<void> _createFixture(Connection database, _FixtureIds fixture) async {
  final now = DateTime.now().toUtc();
  await database.runTx((transaction) async {
    for (final entry in [
      (fixture.driverAId, 'reject-source'),
      (fixture.driverBId, 'redispatch-candidate'),
    ]) {
      await transaction.execute(
        Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash, first_name, last_name, phone,
            is_active, created_at
          ) VALUES (
            @id, @username, 'integration-test-hash',
            'E2E-Test', @firstName, @phone, TRUE, @now
          )
        '''),
        parameters: {
          'id': entry.$1,
          'username': 'atomic-outbox-${entry.$2}-${entry.$1}',
          'firstName': entry.$2,
          'phone': 'atomic-outbox-${entry.$1}',
          'now': now,
        },
      );
    }
    for (final entry in [
      (fixture.vehicleAId, 'A'),
      (fixture.vehicleBId, 'B'),
    ]) {
      await transaction.execute(
        Sql.named('''
          INSERT INTO vehicles (id, plate_number, is_active, created_at)
          VALUES (@id, @plate, TRUE, @now)
        '''),
        parameters: {
          'id': entry.$1,
          'plate':
              'AO-${entry.$2}-${entry.$1.replaceAll('-', '').substring(0, 8)}',
          'now': now,
        },
      );
    }
    for (final entry in [
      (fixture.shiftAId, fixture.driverAId, fixture.vehicleAId, true),
      (fixture.shiftBId, fixture.driverBId, fixture.vehicleBId, false),
    ]) {
      await transaction.execute(
        Sql.named('''
          INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
          VALUES (@id, @driverId, @vehicleId, @startedAt)
        '''),
        parameters: {
          'id': entry.$1,
          'driverId': entry.$2,
          'vehicleId': entry.$3,
          'startedAt': now.subtract(const Duration(hours: 1)),
        },
      );
      await transaction.execute(
        Sql.named('''
          INSERT INTO driver_queue_states (
            shift_id, availability, queue_priority_since, break_started_at,
            has_pending_offer, latitude, longitude, location_updated_at
          ) VALUES (
            @shiftId, 'available', @priority, NULL, @hasPending,
            @latitude, @longitude, @now
          )
        '''),
        parameters: {
          'shiftId': entry.$1,
          'priority': now.subtract(Duration(minutes: entry.$4 ? 2 : 1)),
          'hasPending': entry.$4,
          'latitude': entry.$4 ? 42.6900 : 42.6950,
          'longitude': entry.$4 ? 23.3300 : 23.3350,
          'now': now,
        },
      );
    }
    await transaction.execute(
      Sql.named('''
        INSERT INTO driver_dispatch_states (
          driver_id, consecutive_rejects, penalty_level,
          dispatch_blocked_until, penalty_reset_eligible_at,
          requires_completed_ride_after_penalty
        ) VALUES (@driverId, 2, 0, NULL, NULL, FALSE)
      '''),
      parameters: {'driverId': fixture.driverAId},
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO rides (
          id, pickup, destination, passengers, requested_at, status,
          assigned_driver_id, assigned_vehicle_id, dispatch_round,
          driver_bonus_minor, bonus_decision
        ) VALUES (
          @id, 'ATOMIC-OUTBOX-TEST-PICKUP', 'ATOMIC-OUTBOX-TEST-DESTINATION',
          1, @requestedAt, 'pending', NULL, NULL, 1, 0, 'not_offered'
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
        'id': fixture.originalOfferId,
        'rideId': fixture.rideId,
        'driverId': fixture.driverAId,
        'vehicleId': fixture.vehicleAId,
        'offeredAt': now.subtract(const Duration(seconds: 5)),
        'expiresAt': now.add(const Duration(minutes: 2)),
      },
    );
  });
}

Future<AtomicDriverOfferRejectionResult> _reject(
  Connection database,
  _FixtureIds fixture,
) {
  final dispatchStateRepository = PostgresDriverDispatchStateRepository(
    database: database,
  );
  return AtomicDriverOfferRejectionService(
    transactionRunner: PostgresAtomicDriverOfferRejectionTransactionRunner(
      database: database,
      dispatchStateRepository: dispatchStateRepository,
      outboxRepository: PostgresDriverOfferActionOutboxRepository(),
    ),
    actionIdFactory: () => fixture.actionId,
  ).reject(
    driverId: fixture.driverAId,
    offerId: fixture.originalOfferId,
    idempotencyKey: 'atomic-outbox-e2e-${fixture.actionId}',
  );
}

DriverOfferActionOutboxWorker _worker(
  Connection database, {
  required String leaseToken,
}) => DriverOfferActionOutboxWorker(
  repository: PostgresDriverOfferActionOutboxWorkerRepository(
    database: database,
  ),
  executor: _DiagnosticRedispatchExecutor(_executor(database)),
  leaseDuration: const Duration(minutes: 1),
  maxAttempts: 5,
  leaseTokenFactory: () => leaseToken,
);

final class _DiagnosticRedispatchExecutor
    implements DriverOfferRedispatchExecutor {
  const _DiagnosticRedispatchExecutor(this.delegate);

  final DriverOfferRedispatchExecutor delegate;

  @override
  Future<DriverOfferRedispatchExecutionResult> execute(
    DriverOfferActionOutboxRecord action,
  ) async {
    return _traceStage('executor.execute', () => delegate.execute(action));
  }
}

AutomaticDispatchRedispatchExecutor _executor(Connection database) {
  final offerRepository = _DiagnosticRideOfferRepository(database: database);
  final atomicOfferRepository = PostgresAtomicRideOfferRepository(
    database: database,
  );
  final candidateService = _DiagnosticCandidateService(
    shiftRepository: PostgresDriverShiftRepository(database: database),
    liveLocationRepository: PostgresDriverLiveLocationRepository(
      database: database,
    ),
    dispatchStateRepository: PostgresDriverDispatchStateRepository(
      database: database,
    ),
    routeEstimator: _FakeRouteEstimator(),
  );
  final orchestrator = AutomaticDispatchOrchestrator(
    candidateService: candidateService,
    offerRepository: offerRepository,
    atomicOfferRepository: atomicOfferRepository,
  );
  final redispatchService = AutomaticDispatchRedispatchService(
    rideRepository: _DiagnosticRideRequestRepository(database: database),
    dispatchOrchestrator: orchestrator,
    redispatchOfferRepository: _DiagnosticRedispatchOfferRepository(
      atomicOfferRepository,
    ),
    offerIdFactory: const Uuid().v4,
    now: DateTime.now,
  );
  return AutomaticDispatchRedispatchExecutor(
    offerRepository: offerRepository,
    redispatchService: _DiagnosticRedispatcher(redispatchService),
  );
}

final class _DiagnosticRideOfferRepository extends PostgresRideOfferRepository {
  _DiagnosticRideOfferRepository({required super.database});

  @override
  Future<RideOffer?> findById(String id) =>
      _traceStage('original_offer_lookup', () => super.findById(id));

  @override
  Future<List<RideOffer>> findByRideId(String rideId) => _traceStage(
    'ride_offer_history_lookup',
    () => super.findByRideId(rideId),
  );
}

final class _DiagnosticRideRequestRepository
    extends PostgresRideRequestRepository {
  _DiagnosticRideRequestRepository({required super.database});

  @override
  Future<RideRequest?> findById(String id) =>
      _traceStage('ride_lookup', () => super.findById(id));
}

final class _DiagnosticRedispatcher implements AutomaticDispatchRedispatcher {
  const _DiagnosticRedispatcher(this.delegate);

  final AutomaticDispatchRedispatcher delegate;

  @override
  Future<AutomaticDispatchRedispatchResult> redispatch({
    required String rideId,
    required String actionId,
    required String leaseToken,
  }) async {
    return _traceStage(
      'redispatch.service',
      () => delegate.redispatch(
        rideId: rideId,
        actionId: actionId,
        leaseToken: leaseToken,
      ),
    );
  }
}

final class _DiagnosticCandidateService extends DispatchCandidateService {
  const _DiagnosticCandidateService({
    required super.shiftRepository,
    required super.liveLocationRepository,
    super.dispatchStateRepository,
    required super.routeEstimator,
  });

  @override
  Future<DispatchCandidateBatch> buildBatchForRide({
    required RideRequest ride,
    required DateTime now,
    DispatchCandidatePool? pool,
  }) async {
    return _traceStage(
      'candidates.batch',
      () => super.buildBatchForRide(ride: ride, now: now, pool: pool),
    );
  }

  @override
  Future<DispatchCandidatePool> buildEligiblePool({
    required DateTime now,
  }) async {
    return _traceStage(
      'candidates.pool',
      () => super.buildEligiblePool(now: now),
    );
  }
}

final class _DiagnosticRedispatchOfferRepository
    implements IdempotentAutomaticRedispatchOfferRepository {
  const _DiagnosticRedispatchOfferRepository(this.delegate);

  final IdempotentAutomaticRedispatchOfferRepository delegate;

  @override
  Future<RideOffer?> findOfferByRedispatchActionId(String actionId) =>
      _traceStage(
        'redispatch.lookup',
        () => delegate.findOfferByRedispatchActionId(actionId),
      );

  @override
  Future<IdempotentAutomaticRedispatchPersistenceResult>
  createPendingOfferForRedispatch({
    required RideOffer offer,
    required String actionId,
    required String leaseToken,
  }) => _traceStage(
    'redispatch.offer_commit',
    () => delegate.createPendingOfferForRedispatch(
      offer: offer,
      actionId: actionId,
      leaseToken: leaseToken,
    ),
  );
}

final class _FakeRouteEstimator implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) => _traceStage(
    'route.estimate',
    () async => RouteEstimate(distanceMeters: 750, durationSeconds: 100),
  );
}

Future<Map<String, Object?>> _readActionState(
  Session session,
  _FixtureIds fixture,
) async {
  final rows = await session.execute(
    Sql.named('''
      SELECT
        offer.status AS offer_status,
        queue.has_pending_offer AS queue_pending,
        state.consecutive_rejects,
        state.penalty_level,
        state.dispatch_blocked_until AS blocked_until,
        state.requires_completed_ride_after_penalty AS recovery_required,
        action.action_id,
        action.policy_outcome,
        action.redispatch_status,
        (SELECT count(*)::int FROM driver_offer_action_outbox
         WHERE offer_id = offer.id) AS action_count
      FROM ride_offers offer
      JOIN driver_shifts shift
        ON shift.driver_id = offer.driver_id AND shift.ended_at IS NULL
      JOIN driver_queue_states queue ON queue.shift_id = shift.id
      JOIN driver_dispatch_states state ON state.driver_id = offer.driver_id
      JOIN driver_offer_action_outbox action ON action.offer_id = offer.id
      WHERE offer.id = @offerId
    '''),
    parameters: {'offerId': fixture.originalOfferId},
  );
  return rows.single.toColumnMap();
}

Future<Map<String, Object?>> _readRedispatchState(
  Session session,
  _FixtureIds fixture,
) async {
  final rows = await session.execute(
    Sql.named('''
      SELECT
        (SELECT count(*)::int FROM ride_offers
          WHERE redispatch_action_id = @actionId) AS causal_offer_count,
        causal.driver_id AS causal_offer_driver,
        causal.source AS causal_offer_source,
        causal.status AS causal_offer_status,
        candidate_queue.has_pending_offer AS candidate_queue_pending,
        action.redispatch_status AS outbox_status,
        action.attempt_count,
        action.lease_token,
        action.redispatch_completed_at AS completed_at,
        state.penalty_level,
        state.consecutive_rejects
      FROM driver_offer_action_outbox action
      JOIN ride_offers original ON original.id = action.offer_id
      JOIN driver_dispatch_states state ON state.driver_id = action.driver_id
      LEFT JOIN ride_offers causal
        ON causal.redispatch_action_id = action.action_id
      LEFT JOIN driver_shifts candidate_shift
        ON candidate_shift.driver_id = @candidateDriverId
          AND candidate_shift.ended_at IS NULL
      LEFT JOIN driver_queue_states candidate_queue
        ON candidate_queue.shift_id = candidate_shift.id
      WHERE action.action_id = @actionId
        AND original.id = @originalOfferId
    '''),
    parameters: {
      'actionId': fixture.actionId,
      'candidateDriverId': fixture.driverBId,
      'originalOfferId': fixture.originalOfferId,
    },
  );
  return rows.single.toColumnMap();
}

Future<void> _deleteFixture(Connection database, _FixtureIds fixture) async {
  await database.runTx((transaction) async {
    await transaction.execute(
      Sql.named('''
        DELETE FROM ride_offers
        WHERE redispatch_action_id = @actionId
          AND ride_id = @rideId
      '''),
      parameters: {'actionId': fixture.actionId, 'rideId': fixture.rideId},
    );
    await transaction.execute(
      Sql.named('''
        DELETE FROM driver_offer_action_outbox
        WHERE action_id = @actionId AND offer_id = @offerId
      '''),
      parameters: {
        'actionId': fixture.actionId,
        'offerId': fixture.originalOfferId,
      },
    );
    await transaction.execute(
      Sql.named('''
        DELETE FROM ride_offers
        WHERE id = @offerId AND ride_id = @rideId
      '''),
      parameters: {
        'offerId': fixture.originalOfferId,
        'rideId': fixture.rideId,
      },
    );
    await transaction.execute(
      Sql.named('DELETE FROM rides WHERE id = @rideId'),
      parameters: {'rideId': fixture.rideId},
    );
    await transaction.execute(
      Sql.named('''
        DELETE FROM driver_queue_states
        WHERE shift_id IN (@shiftAId, @shiftBId)
      '''),
      parameters: {'shiftAId': fixture.shiftAId, 'shiftBId': fixture.shiftBId},
    );
    await transaction.execute(
      Sql.named('''
        DELETE FROM driver_shifts
        WHERE id IN (@shiftAId, @shiftBId)
      '''),
      parameters: {'shiftAId': fixture.shiftAId, 'shiftBId': fixture.shiftBId},
    );
    await transaction.execute(
      Sql.named('''
        DELETE FROM driver_dispatch_states
        WHERE driver_id = @driverId
      '''),
      parameters: {'driverId': fixture.driverAId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM vehicles WHERE id IN (@a, @b)'),
      parameters: {'a': fixture.vehicleAId, 'b': fixture.vehicleBId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM drivers WHERE id IN (@a, @b)'),
      parameters: {'a': fixture.driverAId, 'b': fixture.driverBId},
    );
  });
}

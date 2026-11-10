import 'package:postgres/postgres.dart';

import '../dispatch/driver_dispatch_state.dart';
import 'test_driver_penalty_admin.dart';

/// Transactional reset for the two local City6 test drivers.
///
/// The executable is the only production caller and fixes the target to
/// localhost:5432/city6 plus the hard-coded test-driver allowlist. Tests may
/// use unique fixture IDs against localhost:5433/city6_test.
class PostgresTestDriverPenaltyResetService {
  PostgresTestDriverPenaltyResetService({
    required this.database,
    required List<String> driverIds,
    required this.expectedDatabase,
    required this.expectedUsername,
    required this.expectedPort,
  }) : driverIds = List.unmodifiable(driverIds.toSet().toList()..sort()) {
    if (this.driverIds.isEmpty || this.driverIds.length != driverIds.length) {
      throw ArgumentError('Driver IDs must be non-empty and unique.');
    }
    final isLocalCity6 = expectedDatabase == 'city6' && expectedPort == 5432;
    final isIsolatedTestDb =
        expectedDatabase == 'city6_test' && expectedPort == 5433;
    if (!isLocalCity6 && !isIsolatedTestDb) {
      throw ArgumentError(
        'Only local city6:5432 or city6_test:5433 is allowed.',
      );
    }
    if (isLocalCity6 && expectedUsername != 'city6_app') {
      throw ArgumentError('Local city6 reset must use the city6_app role.');
    }
    if (isLocalCity6 &&
        !this.driverIds.every(
          TestDriverPenaltyAdmin.allowedDriverIds.contains,
        )) {
      throw ArgumentError(
        'Production-target reset is outside the test allowlist.',
      );
    }
  }

  final SessionExecutor database;
  final List<String> driverIds;
  final String expectedDatabase;
  final String expectedUsername;
  final int expectedPort;

  Future<TestDriverPenaltyResetResult> resetAll() =>
      database.runTx(resetInTransaction);

  /// The transaction-aware entry point is also used by isolated integration
  /// tests, which can roll back their fixture and reset together.
  Future<TestDriverPenaltyResetResult> resetInTransaction(
    TxSession transaction,
  ) async {
    await _verifyDatabaseIdentity(transaction);
    final databaseNow = await _databaseNow(transaction);

    final driverRows = await transaction.execute(
      Sql.named('SELECT id FROM drivers WHERE id = ANY(@driverIds)'),
      parameters: {'driverIds': driverIds},
    );
    final foundDriverIds = driverRows.map((row) => row[0] as String).toSet();
    final missingDriverIds = driverIds
        .where((id) => !foundDriverIds.contains(id))
        .toList();
    if (missingDriverIds.isNotEmpty) {
      throw TestDriverPenaltyResetException(
        'testDriverMissing',
        'A test Driver account is missing.',
      );
    }

    // The ignored-offer worker locks offer -> ride -> dispatch state. Keep the
    // same order here so a reset racing recovery cannot deadlock or apply a
    // stale penalty after the reset. Pending offers are included only after
    // their server-side expiry time has passed; their status/history is not
    // rewritten, and the timeout worker remains responsible for continuation.
    final candidates = await transaction.execute(
      Sql.named('''
        SELECT
          o.id,
          o.ride_id,
          o.driver_id,
          o.dispatch_round,
          o.status,
          o.expires_at,
          o.offered_at,
          o.displayed_at
        FROM ride_offers o
        JOIN rides r ON r.id = o.ride_id
        LEFT JOIN ignored_offer_penalty_tracking t ON t.offer_id = o.id
        WHERE o.driver_id = ANY(@driverIds)
          AND (
            o.status = 'expired'
            OR (o.status = 'pending' AND o.expires_at <= @databaseNow)
          )
          AND o.displayed_at IS NOT NULL
          AND o.displayed_at < o.expires_at
          AND t.offer_id IS NULL
          AND r.status <> 'cancelled'
          AND NOT (
            r.status = 'waitingForVehicle'
            AND r.requested_at <= @databaseNow - INTERVAL '30 minutes'
          )
          AND o.offered_at >= r.requested_at
          AND o.offered_at < r.requested_at + INTERVAL '20 minutes'
        ORDER BY o.id
        FOR UPDATE OF o
      '''),
      parameters: {'driverIds': driverIds, 'databaseNow': databaseNow},
    );

    final rideIds = candidates.map((row) => row[1] as String).toSet().toList()
      ..sort();
    final lockedRides = <String, _RidePenaltyContext>{};
    for (final rideId in rideIds) {
      final rows = await transaction.execute(
        Sql.named('''
          SELECT status, requested_at
          FROM rides
          WHERE id = @rideId
          FOR UPDATE
        '''),
        parameters: {'rideId': rideId},
      );
      if (rows.isNotEmpty) {
        final row = rows.single.toColumnMap();
        lockedRides[rideId] = _RidePenaltyContext(
          status: row['status'] as String,
          requestedAt: (row['requested_at'] as DateTime).toUtc(),
        );
      }
    }

    // Lock active shift/queue rows in stable driver order. This serializes
    // with offer creation/timeout without updating any queue or FIFO column.
    await transaction.execute(
      Sql.named('''
        SELECT s.driver_id, q.has_pending_offer
        FROM driver_shifts s
        JOIN driver_queue_states q ON q.shift_id = s.id
        WHERE s.driver_id = ANY(@driverIds)
          AND s.ended_at IS NULL
        ORDER BY s.driver_id, s.id
        FOR UPDATE OF s, q
      '''),
      parameters: {'driverIds': driverIds},
    );

    final activeOfferRows = await transaction.execute(
      Sql.named('''
        SELECT count(*)
        FROM ride_offers
        WHERE driver_id = ANY(@driverIds)
          AND status = 'pending'
          AND expires_at > @databaseNow
      '''),
      parameters: {'driverIds': driverIds, 'databaseNow': databaseNow},
    );
    if ((activeOfferRows.single[0] as int) > 0) {
      throw TestDriverPenaltyResetException(
        'activeOffer',
        'An active offer is still pending for a test Driver.',
      );
    }
    // A stale queue marker caused by an already-expired offer is deliberately
    // left untouched. Only a still-live pending offer blocks RESET; timeout
    // processing remains responsible for releasing queue state.

    final activeRideRows = await transaction.execute(
      Sql.named('''
        SELECT count(*)
        FROM rides
        WHERE assigned_driver_id = ANY(@driverIds)
          AND status IN ('reserved', 'accepted', 'driverArriving', 'inProgress')
      '''),
      parameters: {'driverIds': driverIds},
    );
    final activeReservationRows = await transaction.execute(
      Sql.named('''
        SELECT count(*)
        FROM ride_reservations
        WHERE driver_id = ANY(@driverIds)
          AND ended_at IS NULL
      '''),
      parameters: {'driverIds': driverIds},
    );
    if ((activeRideRows.single[0] as int) > 0 ||
        (activeReservationRows.single[0] as int) > 0) {
      throw TestDriverPenaltyResetException(
        'activeRide',
        'A test Driver has a current or reserved ride.',
      );
    }

    final suppressedOffersByDriver = <String, List<String>>{
      for (final id in driverIds) id: <String>[],
    };
    for (final candidate in candidates) {
      final row = candidate.toColumnMap();
      final offerId = row['id'] as String;
      final driverId = row['driver_id'] as String;
      final rideId = row['ride_id'] as String;
      final context = lockedRides[rideId];
      if (context == null ||
          context.status == 'cancelled' ||
          (context.status == 'waitingForVehicle' &&
              !databaseNow.isBefore(
                context.requestedAt.add(const Duration(minutes: 30)),
              ))) {
        continue;
      }

      final inserted = await transaction.execute(
        Sql.named('''
          INSERT INTO ignored_offer_penalty_tracking (
            offer_id, driver_id, dispatch_round, processed_at
          ) VALUES (@offerId, @driverId, @dispatchRound, @processedAt)
          ON CONFLICT (offer_id) DO NOTHING
          RETURNING offer_id
        '''),
        parameters: {
          'offerId': offerId,
          'driverId': driverId,
          'dispatchRound': row['dispatch_round'],
          'processedAt': databaseNow,
        },
      );
      if (inserted.isNotEmpty) {
        suppressedOffersByDriver[driverId]!.add(offerId);
      }
    }

    // Ensure rows exist and lock them deterministically, matching the penalty
    // worker's per-driver serialization. Only dispatch-state columns change.
    for (final driverId in driverIds) {
      await transaction.execute(
        Sql.named('''
          INSERT INTO driver_dispatch_states (driver_id)
          VALUES (@driverId)
          ON CONFLICT (driver_id) DO NOTHING
        '''),
        parameters: {'driverId': driverId},
      );
    }
    final stateRows = await transaction.execute(
      Sql.named('''
        SELECT
          driver_id,
          consecutive_rejects,
          penalty_level,
          dispatch_blocked_until,
          penalty_reset_eligible_at,
          requires_completed_ride_after_penalty
        FROM driver_dispatch_states
        WHERE driver_id = ANY(@driverIds)
        ORDER BY driver_id
        FOR UPDATE
      '''),
      parameters: {'driverIds': driverIds},
    );

    final results = <TestDriverPenaltyResetDriverResult>[];
    for (final row in stateRows) {
      final values = row.toColumnMap();
      final driverId = values['driver_id'] as String;
      final before = _stateFromRow(driverId, values);
      final after = TestDriverPenaltyAdmin.apply(
        before,
        TestDriverPenaltyAction.fullReset,
      );
      await transaction.execute(
        Sql.named('''
          UPDATE driver_dispatch_states SET
            consecutive_rejects = 0,
            penalty_level = 0,
            dispatch_blocked_until = NULL,
            penalty_reset_eligible_at = NULL,
            requires_completed_ride_after_penalty = FALSE,
            updated_at = @updatedAt
          WHERE driver_id = @driverId
        '''),
        parameters: {'driverId': driverId, 'updatedAt': databaseNow},
      );
      results.add(
        TestDriverPenaltyResetDriverResult(
          driverId: driverId,
          before: before,
          after: after,
          suppressedOfferIds: List.unmodifiable(
            suppressedOffersByDriver[driverId]!,
          ),
        ),
      );
    }

    return TestDriverPenaltyResetResult(
      completedAt: databaseNow,
      drivers: List.unmodifiable(results),
    );
  }

  Future<void> _verifyDatabaseIdentity(TxSession transaction) async {
    final rows = await transaction.execute(
      Sql('''
        SELECT current_database(), current_user, current_schema(),
          host(inet_server_addr()), inet_server_port()
      '''),
    );
    final row = rows.single;
    if (row[0] != expectedDatabase ||
        row[1] != expectedUsername ||
        row[2] != 'public' ||
        !{'127.0.0.1', '::1'}.contains(row[3]) ||
        row[4] != expectedPort) {
      throw TestDriverPenaltyResetException(
        'databaseIdentityMismatch',
        'Database identity check failed; no reset was applied.',
      );
    }
  }

  Future<DateTime> _databaseNow(TxSession transaction) async {
    final rows = await transaction.execute(
      Sql('SELECT clock_timestamp() AS database_now'),
    );
    return (rows.single.toColumnMap()['database_now'] as DateTime).toUtc();
  }

  DriverDispatchState _stateFromRow(
    String driverId,
    Map<String, dynamic> row,
  ) => DriverDispatchState(
    driverId: driverId,
    consecutiveRejects: row['consecutive_rejects'] as int,
    penaltyLevel: row['penalty_level'] as int,
    dispatchBlockedUntil: (row['dispatch_blocked_until'] as DateTime?)?.toUtc(),
    penaltyResetEligibleAt: (row['penalty_reset_eligible_at'] as DateTime?)
        ?.toUtc(),
    requiresCompletedRideAfterPenalty:
        row['requires_completed_ride_after_penalty'] as bool,
  );
}

class TestDriverPenaltyResetResult {
  const TestDriverPenaltyResetResult({
    required this.completedAt,
    required this.drivers,
  });

  final DateTime completedAt;
  final List<TestDriverPenaltyResetDriverResult> drivers;

  int get suppressedOfferCount => drivers.fold(
    0,
    (total, driver) => total + driver.suppressedOfferIds.length,
  );
}

class TestDriverPenaltyResetDriverResult {
  const TestDriverPenaltyResetDriverResult({
    required this.driverId,
    required this.before,
    required this.after,
    required this.suppressedOfferIds,
  });

  final String driverId;
  final DriverDispatchState before;
  final DriverDispatchState after;
  final List<String> suppressedOfferIds;
}

class TestDriverPenaltyResetException implements Exception {
  const TestDriverPenaltyResetException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class _RidePenaltyContext {
  const _RidePenaltyContext({required this.status, required this.requestedAt});

  final String status;
  final DateTime requestedAt;
}

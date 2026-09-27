import 'package:postgres/postgres.dart';

import 'active_driver_shift.dart';
import 'driver_queue_state.dart';
import 'driver_shift_repository.dart';

class PostgresDriverShiftRepository implements DriverShiftRepository {
  final SessionExecutor database;

  PostgresDriverShiftRepository({required this.database});

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            s.id AS shift_id,
            s.driver_id,
            s.vehicle_id,
            s.started_at,
            s.protected_breaks_used,
            q.availability,
            q.queue_priority_since,
            q.break_started_at,
            q.has_pending_offer
          FROM driver_shifts s
          JOIN driver_queue_states q
            ON q.shift_id = s.id
          WHERE s.driver_id = @driverId
            AND s.ended_at IS NULL
          LIMIT 1
        '''),
        parameters: {'driverId': driverId},
      );

      if (result.isEmpty) {
        return null;
      }

      return _shiftFromRow(result.first.toColumnMap());
    });
  }

  @override
  Future<List<ActiveDriverShift>> findAllActive() {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            s.id AS shift_id,
            s.driver_id,
            s.vehicle_id,
            s.started_at,
            s.protected_breaks_used,
            q.availability,
            q.queue_priority_since,
            q.break_started_at,
            q.has_pending_offer
          FROM driver_shifts s
          JOIN driver_queue_states q
            ON q.shift_id = s.id
          WHERE s.ended_at IS NULL
          ORDER BY
            q.queue_priority_since ASC,
            s.driver_id ASC
        '''),
      );

      return result.map((row) => _shiftFromRow(row.toColumnMap())).toList();
    });
  }

  @override
  Future<ActiveDriverShift> startShift({
    required String shiftId,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
  }) {
    final startedAtUtc = startedAt.toUtc();

    return database.runTx((transaction) async {
      final shiftResult = await transaction.execute(
        Sql.named('''
          INSERT INTO driver_shifts (
            id,
            driver_id,
            vehicle_id,
            started_at,
            protected_breaks_used
          )
          SELECT
            @shiftId,
            d.id,
            v.id,
            @startedAt,
            0
          FROM drivers d
          CROSS JOIN vehicles v
          WHERE d.id = @driverId
            AND d.is_active = TRUE
            AND v.id = @vehicleId
            AND v.is_active = TRUE
          RETURNING
            id,
            driver_id,
            vehicle_id,
            started_at,
            protected_breaks_used
        '''),
        parameters: {
          'shiftId': shiftId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'startedAt': startedAtUtc,
        },
      );

      if (shiftResult.isEmpty) {
        throw StateError('Driver or vehicle does not exist or is inactive.');
      }

      await transaction.execute(
        Sql.named('''
          INSERT INTO driver_queue_states (
            shift_id,
            availability,
            queue_priority_since,
            break_started_at,
            has_pending_offer
          )
          VALUES (
            @shiftId,
            'available',
            @queuePrioritySince,
            NULL,
            FALSE
          )
        '''),
        parameters: {'shiftId': shiftId, 'queuePrioritySince': startedAtUtc},
      );

      final queueState = DriverQueueState.restore(
        driverId: driverId,
        queuePrioritySince: startedAtUtc,
        availability: DriverQueueAvailability.available,
        shortBreaksUsed: 0,
        breakStartedAt: null,
        hasPendingOffer: false,
      );

      return ActiveDriverShift.restore(
        id: shiftId,
        driverId: driverId,
        vehicleId: vehicleId,
        startedAt: startedAtUtc,
        queueState: queueState,
      );
    });
  }

  @override
  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  }) {
    return database.runTx((transaction) async {
      final shiftResult = await transaction.execute(
        Sql.named('''
          UPDATE driver_shifts
          SET protected_breaks_used = @shortBreaksUsed
          WHERE id = @shiftId
            AND driver_id = @driverId
            AND ended_at IS NULL
          RETURNING
            id,
            driver_id,
            vehicle_id,
            started_at,
            protected_breaks_used
        '''),
        parameters: {
          'shiftId': shiftId,
          'driverId': queueState.driverId,
          'shortBreaksUsed': queueState.shortBreaksUsed,
        },
      );

      if (shiftResult.isEmpty) {
        throw StateError('Active shift was not found for driver.');
      }

      final queueResult = await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET
            availability = @availability,
            queue_priority_since = @queuePrioritySince,
            break_started_at = @breakStartedAt,
            has_pending_offer = @hasPendingOffer
          WHERE shift_id = @shiftId
          RETURNING shift_id
        '''),
        parameters: {
          'shiftId': shiftId,
          'availability': queueState.availability.name,
          'queuePrioritySince': queueState.queuePrioritySince.toUtc(),
          'breakStartedAt': queueState.breakStartedAt?.toUtc(),
          'hasPendingOffer': queueState.hasPendingOffer,
        },
      );

      if (queueResult.isEmpty) {
        throw StateError('Queue state was not found for active shift.');
      }

      final shiftRow = shiftResult.first.toColumnMap();

      return ActiveDriverShift.restore(
        id: shiftRow['id'] as String,
        driverId: shiftRow['driver_id'] as String,
        vehicleId: shiftRow['vehicle_id'] as String,
        startedAt: (shiftRow['started_at'] as DateTime).toUtc(),
        queueState: queueState,
      );
    });
  }

  @override
  Future<void> endShift({required String shiftId, required DateTime endedAt}) {
    final endedAtUtc = endedAt.toUtc();

    return database.runTx((transaction) async {
      final currentResult = await transaction.execute(
        Sql.named('''
          SELECT
            s.started_at,
            q.has_pending_offer
          FROM driver_shifts s
          JOIN driver_queue_states q
            ON q.shift_id = s.id
          WHERE s.id = @shiftId
            AND s.ended_at IS NULL
          FOR UPDATE OF s, q
        '''),
        parameters: {'shiftId': shiftId},
      );

      if (currentResult.isEmpty) {
        throw StateError('Active shift was not found.');
      }

      final current = currentResult.first.toColumnMap();

      final startedAt = (current['started_at'] as DateTime).toUtc();

      if (endedAtUtc.isBefore(startedAt)) {
        throw ArgumentError.value(
          endedAt,
          'endedAt',
          'Shift cannot end before it started.',
        );
      }

      if (current['has_pending_offer'] as bool) {
        throw StateError('Shift cannot end while an offer is pending.');
      }

      await transaction.execute(
        Sql.named('''
          DELETE FROM driver_queue_states
          WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftId},
      );

      final updateResult = await transaction.execute(
        Sql.named('''
          UPDATE driver_shifts
          SET ended_at = @endedAt
          WHERE id = @shiftId
            AND ended_at IS NULL
          RETURNING id
        '''),
        parameters: {'shiftId': shiftId, 'endedAt': endedAtUtc},
      );

      if (updateResult.isEmpty) {
        throw StateError('Active shift could not be ended.');
      }
    });
  }

  ActiveDriverShift _shiftFromRow(Map<String, dynamic> row) {
    final driverId = row['driver_id'] as String;

    final queueState = DriverQueueState.restore(
      driverId: driverId,
      queuePrioritySince: (row['queue_priority_since'] as DateTime).toUtc(),
      availability: DriverQueueAvailability.values.byName(
        row['availability'] as String,
      ),
      shortBreaksUsed: row['protected_breaks_used'] as int,
      breakStartedAt: (row['break_started_at'] as DateTime?)?.toUtc(),
      hasPendingOffer: row['has_pending_offer'] as bool,
    );

    return ActiveDriverShift.restore(
      id: row['shift_id'] as String,
      driverId: driverId,
      vehicleId: row['vehicle_id'] as String,
      startedAt: (row['started_at'] as DateTime).toUtc(),
      queueState: queueState,
    );
  }
}

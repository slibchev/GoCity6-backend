import 'package:postgres/postgres.dart';

import 'driver_dispatch_state.dart';
import 'driver_dispatch_state_repository.dart';

class PostgresDriverDispatchStateRepository
    implements DriverDispatchStateRepository {
  final SessionExecutor database;

  PostgresDriverDispatchStateRepository({required this.database});
  @override
  Future<DriverDispatchState> updateAtomically({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  }) {
    return database.runTx(
      (tx) => updateAtomicallyInTransaction(
        transaction: tx,
        driverId: driverId,
        transform: transform,
      ),
    );
  }

  /// Applies the existing policy transformation using the caller's transaction.
  /// This method never starts, commits, or rolls back a transaction itself.
  Future<DriverDispatchState> updateAtomicallyInTransaction({
    required TxSession transaction,
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  }) async {
    await transaction.execute(
      Sql.named('''
          INSERT INTO driver_dispatch_states (driver_id)
          VALUES (@driverId)
          ON CONFLICT (driver_id) DO NOTHING
        '''),
      parameters: {'driverId': driverId},
    );

    final rows = await transaction.execute(
      Sql.named('''
          SELECT
            driver_id,
            consecutive_rejects,
            penalty_level,
            dispatch_blocked_until,
            penalty_reset_eligible_at,
            requires_completed_ride_after_penalty
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
          FOR UPDATE
        '''),
      parameters: {'driverId': driverId},
    );

    final row = rows.single.toColumnMap();

    final current = DriverDispatchState(
      driverId: row['driver_id'] as String,
      consecutiveRejects: row['consecutive_rejects'] as int,
      penaltyLevel: row['penalty_level'] as int,
      dispatchBlockedUntil: (row['dispatch_blocked_until'] as DateTime?)
          ?.toUtc(),
      penaltyResetEligibleAt: (row['penalty_reset_eligible_at'] as DateTime?)
          ?.toUtc(),
      requiresCompletedRideAfterPenalty:
          row['requires_completed_ride_after_penalty'] as bool,
    );

    final next = transform(current);

    if (next.driverId != driverId) {
      throw StateError('Driver ID cannot be changed.');
    }

    await transaction.execute(
      Sql.named('''
          UPDATE driver_dispatch_states
          SET
            consecutive_rejects = @rejects,
            penalty_level = @level,
            dispatch_blocked_until = @blockedUntil,
            penalty_reset_eligible_at = @resetEligibleAt,
            requires_completed_ride_after_penalty =
              @requiresCompletedRideAfterPenalty,
            updated_at = NOW()
          WHERE driver_id = @driverId
        '''),
      parameters: {
        'driverId': driverId,
        'rejects': next.consecutiveRejects,
        'level': next.penaltyLevel,
        'blockedUntil': next.dispatchBlockedUntil,
        'resetEligibleAt': next.penaltyResetEligibleAt,
        'requiresCompletedRideAfterPenalty':
            next.requiresCompletedRideAfterPenalty,
      },
    );

    return next;
  }

  @override
  Future<DriverDispatchState?> findByDriverId(String driverId) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            driver_id,
            consecutive_rejects,
            penalty_level,
            dispatch_blocked_until,
            penalty_reset_eligible_at,
            requires_completed_ride_after_penalty
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
          LIMIT 1
        '''),
        parameters: {'driverId': driverId},
      );

      if (result.isEmpty) {
        return null;
      }

      final row = result.first.toColumnMap();

      return DriverDispatchState(
        driverId: row['driver_id'] as String,
        consecutiveRejects: row['consecutive_rejects'] as int,
        penaltyLevel: row['penalty_level'] as int,
        dispatchBlockedUntil: (row['dispatch_blocked_until'] as DateTime?)
            ?.toUtc(),
        penaltyResetEligibleAt: (row['penalty_reset_eligible_at'] as DateTime?)
            ?.toUtc(),
        requiresCompletedRideAfterPenalty:
            row['requires_completed_ride_after_penalty'] as bool,
      );
    });
  }

  @override
  Future<DriverDispatchState> save(DriverDispatchState state) {
    return database.run((session) async {
      await session.execute(
        Sql.named('''
          INSERT INTO driver_dispatch_states (
            driver_id,
            consecutive_rejects,
            penalty_level,
            dispatch_blocked_until,
            penalty_reset_eligible_at,
            requires_completed_ride_after_penalty,
            updated_at
          )
          VALUES (
            @driverId,
            @consecutiveRejects,
            @penaltyLevel,
            @dispatchBlockedUntil,
            @penaltyResetEligibleAt,
            @requiresCompletedRideAfterPenalty,
            NOW()
          )
          ON CONFLICT (driver_id)
          DO UPDATE SET
            consecutive_rejects = EXCLUDED.consecutive_rejects,
            penalty_level = EXCLUDED.penalty_level,
            dispatch_blocked_until = EXCLUDED.dispatch_blocked_until,
            penalty_reset_eligible_at =
              EXCLUDED.penalty_reset_eligible_at,
            requires_completed_ride_after_penalty =
              EXCLUDED.requires_completed_ride_after_penalty,
            updated_at = NOW()
        '''),
        parameters: {
          'driverId': state.driverId,
          'consecutiveRejects': state.consecutiveRejects,
          'penaltyLevel': state.penaltyLevel,
          'dispatchBlockedUntil': state.dispatchBlockedUntil?.toUtc(),
          'penaltyResetEligibleAt': state.penaltyResetEligibleAt?.toUtc(),
          'requiresCompletedRideAfterPenalty':
              state.requiresCompletedRideAfterPenalty,
        },
      );

      return state;
    });
  }
}

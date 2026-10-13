import 'package:postgres/postgres.dart';

import 'driver_dispatch_state.dart';
import 'driver_dispatch_state_repository.dart';

class PostgresDriverDispatchStateRepository
    implements DriverDispatchStateRepository {
  final SessionExecutor database;

  PostgresDriverDispatchStateRepository({
    required this.database,
  });

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
            penalty_reset_eligible_at
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
          LIMIT 1
        '''),
        parameters: {
          'driverId': driverId,
        },
      );

      if (result.isEmpty) {
        return null;
      }

      final row = result.first.toColumnMap();

      return DriverDispatchState(
        driverId: row['driver_id'] as String,
        consecutiveRejects: row['consecutive_rejects'] as int,
        penaltyLevel: row['penalty_level'] as int,
        dispatchBlockedUntil:
            (row['dispatch_blocked_until'] as DateTime?)?.toUtc(),
        penaltyResetEligibleAt:
            (row['penalty_reset_eligible_at'] as DateTime?)?.toUtc(),
      );
    });
  }

  @override
  Future<DriverDispatchState> save(
    DriverDispatchState state,
  ) {
    return database.run((session) async {
      await session.execute(
        Sql.named('''
          INSERT INTO driver_dispatch_states (
            driver_id,
            consecutive_rejects,
            penalty_level,
            dispatch_blocked_until,
            penalty_reset_eligible_at,
            updated_at
          )
          VALUES (
            @driverId,
            @consecutiveRejects,
            @penaltyLevel,
            @dispatchBlockedUntil,
            @penaltyResetEligibleAt,
            NOW()
          )
          ON CONFLICT (driver_id)
          DO UPDATE SET
            consecutive_rejects = EXCLUDED.consecutive_rejects,
            penalty_level = EXCLUDED.penalty_level,
            dispatch_blocked_until = EXCLUDED.dispatch_blocked_until,
            penalty_reset_eligible_at =
              EXCLUDED.penalty_reset_eligible_at,
            updated_at = NOW()
        '''),
        parameters: {
          'driverId': state.driverId,
          'consecutiveRejects': state.consecutiveRejects,
          'penaltyLevel': state.penaltyLevel,
          'dispatchBlockedUntil':
              state.dispatchBlockedUntil?.toUtc(),
          'penaltyResetEligibleAt':
              state.penaltyResetEligibleAt?.toUtc(),
        },
      );

      return state;
    });
  }
}
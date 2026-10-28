import 'package:postgres/postgres.dart';

import 'driver_queue_state.dart';

/// Persists expired short breaks using PostgreSQL time.
///
/// Callers run this inside the same transaction as the state read or
/// dispatch-candidate load, so a restart cannot leave a ten-minute break
/// blocking the driver indefinitely.
Future<void> materializeExpiredShortBreaks(
  Session session, {
  String? driverId,
}) async {
  final driverFilter = driverId == null ? '' : 'AND s.driver_id = @driverId';
  final parameters = <String, Object?>{
    'durationSeconds': DriverQueueState.shortBreakDuration.inSeconds,
    'driverId': ?driverId,
  };

  await session.execute(
    Sql.named('''
      WITH expired AS MATERIALIZED (
        SELECT q.shift_id, q.active_break_request_id
        FROM driver_queue_states q
        JOIN driver_shifts s ON s.id = q.shift_id
        WHERE s.ended_at IS NULL
          AND q.availability = 'shortBreak'
          AND q.break_started_at <=
            clock_timestamp() - (@durationSeconds * INTERVAL '1 second')
          $driverFilter
        FOR UPDATE OF q
      ), released AS (
        UPDATE driver_queue_states q
        SET availability = 'available',
            break_started_at = NULL,
            active_break_request_id = NULL
        FROM expired e
        WHERE q.shift_id = e.shift_id
        RETURNING q.shift_id
      )
      UPDATE driver_break_requests request
      SET status = 'completed', ended_at = clock_timestamp()
      FROM expired e
      JOIN released r ON r.shift_id = e.shift_id
      WHERE request.request_id = e.active_break_request_id
        AND request.status = 'active'
    '''),
    parameters: parameters,
  );
}

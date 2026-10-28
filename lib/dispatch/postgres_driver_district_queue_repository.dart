import 'package:postgres/postgres.dart';

import 'driver_district_queue.dart';
import 'driver_district_queue_repository.dart';

final class PostgresDriverDistrictQueueRepository
    implements DriverDistrictQueueRepository {
  const PostgresDriverDistrictQueueRepository({required this.database});

  final SessionExecutor database;

  @override
  Future<DriverDistrictObservationResult> observeLocation({
    required String driverId,
    required DateTime receivedAt,
    required DateTime? gpsFixAt,
    required bool gpsFixIsPlausible,
    required int? districtObjectId,
    required DriverDistrictTransitionPolicy policy,
  }) {
    final receivedTimestamp = receivedAt.toUtc();
    final fixTimestamp = gpsFixAt?.toUtc();
    return database.runTx((transaction) async {
      final rows = await transaction.execute(
        Sql.named('''
          SELECT
            q.shift_id,
            q.location_updated_at,
            q.district_object_id,
            q.district_entered_at,
            q.district_last_observed_at,
            q.pending_district_object_id,
            q.pending_district_since,
            q.pending_district_last_seen_at,
            q.pending_district_observations
          FROM driver_shifts s
          JOIN driver_queue_states q ON q.shift_id = s.id
          WHERE s.driver_id = @driverId
            AND s.ended_at IS NULL
          FOR UPDATE OF q
        '''),
        parameters: {'driverId': driverId},
      );

      if (rows.isEmpty) {
        return DriverDistrictObservationResult.noActiveShift;
      }

      final row = rows.single.toColumnMap();
      final savedLocationAt = (row['location_updated_at'] as DateTime?)
          ?.toUtc();
      if (savedLocationAt == null || savedLocationAt != receivedTimestamp) {
        return DriverDistrictObservationResult.staleObservation;
      }

      await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET gps_fix_at = @gpsFixAt
          WHERE shift_id = @shiftId
        '''),
        parameters: {
          'shiftId': row['shift_id'],
          'gpsFixAt': gpsFixIsPlausible ? fixTimestamp : null,
        },
      );

      if (!gpsFixIsPlausible || fixTimestamp == null) {
        return DriverDistrictObservationResult.invalidGpsFixTimestamp;
      }

      final current = DriverDistrictQueueMembership.restore(
        districtObjectId: row['district_object_id'] as int?,
        enteredAt: (row['district_entered_at'] as DateTime?)?.toUtc(),
        lastObservedAt: (row['district_last_observed_at'] as DateTime?)
            ?.toUtc(),
        pendingDistrictObjectId: row['pending_district_object_id'] as int?,
        pendingSince: (row['pending_district_since'] as DateTime?)?.toUtc(),
        pendingLastSeenAt: (row['pending_district_last_seen_at'] as DateTime?)
            ?.toUtc(),
        pendingObservations: row['pending_district_observations'] as int,
      );
      final transition = current.observe(
        observedDistrictObjectId: districtObjectId,
        gpsFixAt: fixTimestamp,
        confirmedAt: receivedTimestamp,
        policy: policy,
      );

      if (identical(transition.membership, current)) {
        return transition.result;
      }

      final next = transition.membership;
      await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET
            district_object_id = @districtObjectId,
            district_entered_at = @districtEnteredAt,
            district_last_observed_at = @lastObservedAt,
            pending_district_object_id = @pendingDistrictObjectId,
            pending_district_since = @pendingSince,
            pending_district_last_seen_at = @pendingLastSeenAt,
            pending_district_observations = @pendingObservations
          WHERE shift_id = @shiftId
        '''),
        parameters: {
          'shiftId': row['shift_id'],
          'districtObjectId': next.districtObjectId,
          'districtEnteredAt': next.enteredAt?.toUtc(),
          'lastObservedAt': next.lastObservedAt?.toUtc(),
          'pendingDistrictObjectId': next.pendingDistrictObjectId,
          'pendingSince': next.pendingSince?.toUtc(),
          'pendingLastSeenAt': next.pendingLastSeenAt?.toUtc(),
          'pendingObservations': next.pendingObservations,
        },
      );

      return transition.result;
    });
  }

  @override
  Future<List<DriverDistrictQueueEntry>> findByDistrictObjectId(
    int districtObjectId,
  ) {
    if (districtObjectId <= 0) {
      throw ArgumentError.value(
        districtObjectId,
        'districtObjectId',
        'District object ID must be positive.',
      );
    }

    return database.run((session) async {
      final rows = await session.execute(
        Sql.named('''
          SELECT
            s.id AS shift_id,
            s.driver_id,
            q.district_object_id,
            q.district_entered_at,
            q.queue_priority_since,
            q.district_last_observed_at,
            GREATEST(q.district_entered_at, q.queue_priority_since)
              AS fifo_priority_at
          FROM driver_shifts s
          JOIN driver_queue_states q ON q.shift_id = s.id
          WHERE s.ended_at IS NULL
            AND q.district_object_id = @districtObjectId
            AND q.district_entered_at IS NOT NULL
            AND q.queue_priority_since IS NOT NULL
          ORDER BY fifo_priority_at ASC, s.driver_id ASC
        '''),
        parameters: {'districtObjectId': districtObjectId},
      );

      return List.unmodifiable(
        rows.map((resultRow) {
          final row = resultRow.toColumnMap();
          return DriverDistrictQueueEntry(
            shiftId: row['shift_id'] as String,
            driverId: row['driver_id'] as String,
            districtObjectId: row['district_object_id'] as int,
            enteredAt: (row['district_entered_at'] as DateTime).toUtc(),
            queuePrioritySince: (row['queue_priority_since'] as DateTime)
                .toUtc(),
            lastObservedAt: (row['district_last_observed_at'] as DateTime?)
                ?.toUtc(),
          );
        }),
      );
    });
  }
}

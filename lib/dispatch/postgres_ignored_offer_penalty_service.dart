import 'package:postgres/postgres.dart';

import 'driver_dispatch_state.dart';
import 'driver_dispatch_policy_service.dart';

class PostgresIgnoredOfferPenaltyService {
  final SessionExecutor database;

  const PostgresIgnoredOfferPenaltyService({required this.database});

  /// Returns true only when a new penalty event was applied.
  Future<bool> recordIgnoredOffer({
    required String offerId,
    required DateTime now,
  }) async {
    final nowUtc = now.toUtc();

    return database.runTx((tx) async {
      // Use the same offer -> ride lock order as offer acceptance and the
      // system-expiration transaction. This prevents a timeout callback from
      // applying an ignored-offer penalty after its waiting-board ride has
      // been cancelled or has crossed the 30-minute expiry boundary.
      final offerRows = await tx.execute(
        Sql.named('''
          SELECT
            id,
            ride_id,
            driver_id,
            dispatch_round,
            expires_at,
            offered_at,
            displayed_at
          FROM ride_offers
          WHERE id = @offerId
            AND status = 'expired'
            AND displayed_at IS NOT NULL
            AND displayed_at < expires_at
          FOR UPDATE
        '''),
        parameters: {'offerId': offerId},
      );

      if (offerRows.isEmpty) {
        return false;
      }

      final offerRow = offerRows.single.toColumnMap();
      final rideRows = await tx.execute(
        Sql.named('''
          SELECT status, requested_at
          FROM rides
          WHERE id = @rideId
          FOR UPDATE
        '''),
        parameters: {'rideId': offerRow['ride_id']},
      );
      if (rideRows.isEmpty) {
        return false;
      }
      final rideRow = rideRows.single.toColumnMap();

      final databaseTimeResult = await tx.execute(
        Sql('SELECT clock_timestamp() AS database_now'),
      );
      final databaseNow =
          (databaseTimeResult.single.toColumnMap()['database_now'] as DateTime)
              .toUtc();
      final requestedAt = (rideRow['requested_at'] as DateTime).toUtc();
      if (rideRow['status'] == 'cancelled' ||
          (rideRow['status'] == 'waitingForVehicle' &&
              !databaseNow.isBefore(
                requestedAt.add(const Duration(minutes: 30)),
              ))) {
        return false;
      }

      // Record the processed event only after confirming that it was not
      // resolved by system cancellation. The primary key makes retries safe.
      final claimed = await tx.execute(
        Sql.named('''
          INSERT INTO ignored_offer_penalty_tracking (
            offer_id,
            driver_id,
            dispatch_round,
            processed_at
          ) VALUES (
            @offerId, @driverId, @dispatchRound, @now
          )
          ON CONFLICT (offer_id) DO NOTHING
          RETURNING offer_id
        '''),
        parameters: {
          'offerId': offerId,
          'driverId': offerRow['driver_id'],
          'dispatchRound': offerRow['dispatch_round'],
          'now': nowUtc,
        },
      );
      if (claimed.isEmpty) return false;

      final driverId = offerRow['driver_id'] as String;
      final dispatchRound = offerRow['dispatch_round'] as int;
      final expiredAt = (offerRow['expires_at'] as DateTime).toUtc();
      final offeredAt = (offerRow['offered_at'] as DateTime).toUtc();

      if (!DriverDispatchPolicyService.isOfferPenaltyEligible(
        requestedAt: requestedAt,
        offeredAt: offeredAt,
      )) {
        // Keep the tracking row so recovery does not retry this offer forever.
        return false;
      }

      // Ensure a state row exists before locking it.
      await tx.execute(
        Sql.named('''
          INSERT INTO driver_dispatch_states (driver_id)
          VALUES (@driverId)
          ON CONFLICT (driver_id) DO NOTHING
        '''),
        parameters: {'driverId': driverId},
      );

      // Serialize penalty updates for this driver.
      final states = await tx.execute(
        Sql.named('''
          SELECT
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

      final state = states.single.toColumnMap();

      final current = DriverDispatchState(
        driverId: driverId,
        consecutiveRejects: state['consecutive_rejects'] as int,
        penaltyLevel: state['penalty_level'] as int,
        dispatchBlockedUntil: (state['dispatch_blocked_until'] as DateTime?)
            ?.toUtc(),
        penaltyResetEligibleAt:
            (state['penalty_reset_eligible_at'] as DateTime?)?.toUtc(),
        requiresCompletedRideAfterPenalty:
            state['requires_completed_ride_after_penalty'] as bool,
      );

      // An ignored offer takes effect at expiry, matching an explicit decline
      // at the time the driver could no longer accept it.
      final next = dispatchRound == 2
          ? DriverDispatchPolicyService.afterBonusOfferRejection(
              current: current,
              rejectedAt: expiredAt,
            )
          : DriverDispatchPolicyService.afterStandardOfferRejection(
              current: current,
              rejectedAt: expiredAt,
            );

      await tx.execute(
        Sql.named('''
          UPDATE driver_dispatch_states
          SET
            consecutive_rejects = @rejects,
            penalty_level = @level,
            dispatch_blocked_until = @blockedUntil,
            penalty_reset_eligible_at = @resetEligibleAt,
            requires_completed_ride_after_penalty =
              @requiresCompletedRideAfterPenalty,
            updated_at = @now
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
          'now': nowUtc,
        },
      );

      return true;
    });
  }

  Future<int> recoverUnprocessedIgnoredOffers({required DateTime now}) async {
    final nowUtc = now.toUtc();

    final rows = await database.run((session) async {
      return session.execute(
        Sql.named('''
      SELECT o.id
      FROM ride_offers o
      JOIN rides r ON r.id = o.ride_id
      LEFT JOIN ignored_offer_penalty_tracking t
        ON t.offer_id = o.id
      WHERE o.status = 'expired'
        AND o.displayed_at IS NOT NULL
        AND o.displayed_at < o.expires_at
        AND t.offer_id IS NULL
        AND r.status <> 'cancelled'
        AND NOT (
          r.status = 'waitingForVehicle'
          AND r.requested_at <= clock_timestamp() - INTERVAL '30 minutes'
        )
      ORDER BY o.expires_at ASC
    '''),
      );
    });

    var processedCount = 0;

    for (final row in rows) {
      final applied = await recordIgnoredOffer(
        offerId: row[0] as String,
        now: nowUtc,
      );

      if (applied) {
        processedCount++;
      }
    }

    return processedCount;
  }
}

import 'package:postgres/postgres.dart';

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
      // Claim only a confirmed displayed, expired offer.
      // The primary key prevents duplicate processing.
      final claimed = await tx.execute(
        Sql.named('''
          INSERT INTO ignored_offer_penalty_tracking (
            offer_id,
            driver_id,
            dispatch_round,
            processed_at
          )
          SELECT
            o.id,
            o.driver_id,
            o.dispatch_round,
            @now
          FROM ride_offers o
          JOIN rides r ON r.id = o.ride_id
          WHERE o.id = @offerId
            AND o.status = 'expired'
            AND o.displayed_at IS NOT NULL
            AND o.displayed_at < o.expires_at
          ON CONFLICT (offer_id) DO NOTHING
          RETURNING offer_id
        '''),
        parameters: {'offerId': offerId, 'now': nowUtc},
      );

      if (claimed.isEmpty) {
        return false;
      }

      final claimedOfferId = claimed.first[0] as String;
      final offerRows = await tx.execute(
        Sql.named('''
          SELECT
            o.driver_id,
            o.dispatch_round,
            o.expires_at,
            o.offered_at,
            r.requested_at
          FROM ride_offers o
          JOIN rides r ON r.id = o.ride_id
          WHERE o.id = @offerId
        '''),
        parameters: {'offerId': claimedOfferId},
      );
      final offerRow = offerRows.single.toColumnMap();
      final driverId = offerRow['driver_id'] as String;
      final dispatchRound = offerRow['dispatch_round'] as int;
      final expiredAt = (offerRow['expires_at'] as DateTime).toUtc();
      final offeredAt = (offerRow['offered_at'] as DateTime).toUtc();
      final requestedAt = (offerRow['requested_at'] as DateTime).toUtc();

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
            penalty_reset_eligible_at
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
          FOR UPDATE
        '''),
        parameters: {'driverId': driverId},
      );

      final state = states.single.toColumnMap();

      var rejects = state['consecutive_rejects'] as int;
      var level = state['penalty_level'] as int;
      DateTime? blockedUntil = (state['dispatch_blocked_until'] as DateTime?)
          ?.toUtc();

      if (dispatchRound == 2) {
        // Bonus offer: immediate 30-minute block.
        rejects = 0;
        blockedUntil = expiredAt.add(DriverDispatchPolicyService.penaltyStep);
      } else {
        rejects++;

        if (rejects >= DriverDispatchPolicyService.maxConsecutiveRejects) {
          rejects = 0;
          level++;

          blockedUntil = expiredAt.add(
            Duration(
              minutes:
                  DriverDispatchPolicyService.penaltyStep.inMinutes * level,
            ),
          );
        }
      }

      await tx.execute(
        Sql.named('''
          UPDATE driver_dispatch_states
          SET
            consecutive_rejects = @rejects,
            penalty_level = @level,
            dispatch_blocked_until = @blockedUntil,
            updated_at = @now
          WHERE driver_id = @driverId
        '''),
        parameters: {
          'driverId': driverId,
          'rejects': rejects,
          'level': level,
          'blockedUntil': blockedUntil,
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
      LEFT JOIN ignored_offer_penalty_tracking t
        ON t.offer_id = o.id
      WHERE o.status = 'expired'
        AND o.displayed_at IS NOT NULL
        AND o.displayed_at < o.expires_at
        AND t.offer_id IS NULL
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

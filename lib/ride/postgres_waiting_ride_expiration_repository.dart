import 'package:postgres/postgres.dart';

import '../dispatch/driver_offer_action_outbox_worker_repository.dart';
import 'waiting_ride_expiration_repository.dart';

/// PostgreSQL implementation for the durable waiting-board expiry sweep.
final class PostgresWaitingRideExpirationRepository
    implements WaitingRideExpirationRepository {
  const PostgresWaitingRideExpirationRepository({required this.database});

  final SessionExecutor database;

  @override
  Future<WaitingRideExpirationBatch> cancelExpiredWaitingRides({
    required int limit,
  }) {
    _validateLimit(limit);

    return database.runTx((transaction) async {
      final nowResult = await transaction.execute(
        Sql('SELECT clock_timestamp() AS database_now'),
      );
      final databaseNow =
          (nowResult.single.toColumnMap()['database_now'] as DateTime).toUtc();
      final cutoff = databaseNow.subtract(const Duration(minutes: 30));

      // Read a bounded candidate page without locks. Offer acceptance locks
      // the offer before it locks the ride, so expiration must use that same
      // order whenever an offer already exists.
      final candidateResult = await transaction.execute(
        Sql.named('''
          SELECT id
          FROM rides
          WHERE status = 'waitingForVehicle'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
            AND requested_at <= @cutoff
            -- Fail closed if a reservation row is still active, even when
            -- persisted ride.status is inconsistent with reservation state.
            AND NOT EXISTS (
              SELECT 1
              FROM ride_reservations reservation
              WHERE reservation.ride_id = rides.id
                AND reservation.ended_at IS NULL
            )
          ORDER BY requested_at ASC, id ASC
          LIMIT @limit
        '''),
        parameters: {'cutoff': cutoff, 'limit': limit},
      );

      final cancelledRideIds = <String>[];
      var expiredOfferCount = 0;

      for (final candidate in candidateResult) {
        final rideId = candidate.toColumnMap()['id'] as String;

        // Lock pending offers first, in the same order as accept/reject and
        // timeout paths. SKIP LOCKED avoids waiting behind an in-flight
        // action; the ride is revalidated after its lock is acquired.
        final pendingOffers = await transaction.execute(
          Sql.named('''
            SELECT id, driver_id, vehicle_id
            FROM ride_offers
            WHERE ride_id = @rideId
              AND status = 'pending'
            ORDER BY id ASC
            FOR UPDATE SKIP LOCKED
          '''),
          parameters: {'rideId': rideId},
        );
        final lockedOfferIds = pendingOffers
            .map((row) => row.toColumnMap()['id'] as String)
            .toSet();

        final rideLock = await transaction.execute(
          Sql.named('''
            SELECT id
            FROM rides
            WHERE id = @rideId
              AND status = 'waitingForVehicle'
              AND assigned_driver_id IS NULL
              AND assigned_vehicle_id IS NULL
              AND requested_at <= @cutoff
              AND NOT EXISTS (
                SELECT 1
                FROM ride_reservations reservation
                WHERE reservation.ride_id = rides.id
                  AND reservation.ended_at IS NULL
              )
            FOR UPDATE SKIP LOCKED
          '''),
          parameters: {'rideId': rideId, 'cutoff': cutoff},
        );
        if (rideLock.isEmpty) {
          continue;
        }

        // A waiting-board offer creator locks the ride first. If it committed
        // a new offer between the candidate read and our ride lock, do not
        // take that offer lock in reverse order here. Leave this ride for the
        // next sweep, which will lock offer -> ride safely.
        final currentPendingOfferIds = await transaction.execute(
          Sql.named('''
            SELECT id
            FROM ride_offers
            WHERE ride_id = @rideId
              AND status = 'pending'
          '''),
          parameters: {'rideId': rideId},
        );
        final hasUnlockedPendingOffer = currentPendingOfferIds.any(
          (row) => !lockedOfferIds.contains(row.toColumnMap()['id'] as String),
        );
        if (hasUnlockedPendingOffer) {
          continue;
        }

        final cancelledResult = await transaction.execute(
          Sql.named('''
            UPDATE rides
            SET status = 'cancelled'
            WHERE id = @rideId
              AND status = 'waitingForVehicle'
              AND assigned_driver_id IS NULL
              AND assigned_vehicle_id IS NULL
              AND requested_at <= @cutoff
              AND NOT EXISTS (
                SELECT 1
                FROM ride_reservations reservation
                WHERE reservation.ride_id = rides.id
                  AND reservation.ended_at IS NULL
              )
            RETURNING id
          '''),
          parameters: {'rideId': rideId, 'cutoff': cutoff},
        );
        if (cancelledResult.isEmpty) {
          continue;
        }
        cancelledRideIds.add(rideId);

        // Offer timeout processing is deliberately bypassed: it can record
        // an ignored-offer penalty and continue dispatch. We invalidate only
        // offers for this ride and preserve the driver's FIFO timestamp.
        for (final pendingOffer in pendingOffers) {
          final offer = pendingOffer.toColumnMap();
          final offerId = offer['id'] as String;
          final driverId = offer['driver_id'] as String;
          final vehicleId = offer['vehicle_id'] as String;

          final resolved = await transaction.execute(
            Sql.named('''
              UPDATE ride_offers
              SET status = 'expired',
                  expires_at = LEAST(
                    expires_at,
                    GREATEST(@resolvedAt, offered_at + INTERVAL '1 microsecond')
                  ),
                  resolved_at = GREATEST(
                    @resolvedAt,
                    offered_at + INTERVAL '1 microsecond'
                  )
              WHERE id = @offerId
                AND status = 'pending'
              RETURNING id
            '''),
            parameters: {'offerId': offerId, 'resolvedAt': databaseNow},
          );
          if (resolved.isEmpty) {
            continue;
          }
          expiredOfferCount++;

          // No penalty, queue-priority update, or continuation callback is
          // performed. Preserve the flag if an unrelated pending offer exists
          // for the same active shift.
          await transaction.execute(
            Sql.named('''
              UPDATE driver_queue_states q
              SET has_pending_offer = FALSE
              FROM driver_shifts s
              WHERE q.shift_id = s.id
                AND s.driver_id = @driverId
                AND s.vehicle_id = @vehicleId
                AND s.ended_at IS NULL
                AND q.has_pending_offer = TRUE
                AND NOT EXISTS (
                  SELECT 1
                  FROM ride_offers other_offer
                  WHERE other_offer.driver_id = s.driver_id
                    AND other_offer.vehicle_id = s.vehicle_id
                    AND other_offer.status = 'pending'
                )
            '''),
            parameters: {'driverId': driverId, 'vehicleId': vehicleId},
          );
        }
      }

      return WaitingRideExpirationBatch(
        cancelledRideIds: List.unmodifiable(cancelledRideIds),
        expiredOfferCount: expiredOfferCount,
      );
    });
  }

  @override
  Future<int> settleOutboxForCancelledRides({required int limit}) {
    _validateLimit(limit);

    return database.runTx((transaction) async {
      final result = await transaction.execute(
        Sql.named('''
          WITH candidates AS (
            SELECT action.action_id
            FROM driver_offer_action_outbox action
            JOIN ride_offers offer ON offer.id = action.offer_id
            JOIN rides ride ON ride.id = offer.ride_id
            WHERE ride.status = 'cancelled'
              AND action.action = 'reject'
              AND action.redispatch_status IN ('queued', 'retryable', 'leased')
            ORDER BY action.created_at ASC, action.action_id ASC
            FOR UPDATE OF action SKIP LOCKED
            LIMIT @limit
          )
          UPDATE driver_offer_action_outbox action
          SET redispatch_status = 'needs_review',
              lease_token = NULL,
              lease_until = NULL,
              last_error_code = @rideCancelledCode,
              redispatch_result = NULL,
              redispatch_completed_at = NULL,
              updated_at = clock_timestamp()
          FROM candidates, ride_offers offer, rides ride
          WHERE action.action_id = candidates.action_id
            AND offer.id = action.offer_id
            AND ride.id = offer.ride_id
          RETURNING action.action_id
        '''),
        parameters: {
          'limit': limit,
          'rideCancelledCode':
              DriverOfferActionOutboxErrorCode.rideCancelled.databaseValue,
        },
      );
      return result.length;
    });
  }

  void _validateLimit(int limit) {
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Limit must be 1 through 1000.',
      );
    }
  }
}

import 'package:postgres/postgres.dart';

import 'atomic_external_ride_repository.dart';
import 'external_ride_session.dart';

class PostgresAtomicExternalRideRepository
    implements AtomicExternalRideRepository {
  final SessionExecutor database;

  PostgresAtomicExternalRideRepository({required this.database});

  @override
  Future<AtomicExternalRideStartResult> startExternalRide({
    required String sessionId,
    required String driverId,
    required DateTime now,
  }) {
    final nowUtc = now.toUtc();

    return database.runTx((transaction) async {
      final shiftResult = await transaction.execute(
        Sql.named('''
          SELECT
            s.id AS shift_id,
            s.vehicle_id,
            q.availability,
            q.has_pending_offer,
            q.break_started_at
          FROM driver_shifts s
          JOIN driver_queue_states q
            ON q.shift_id = s.id
          WHERE s.driver_id = @driverId
            AND s.ended_at IS NULL
          LIMIT 1
          FOR UPDATE OF s, q
        '''),
        parameters: {'driverId': driverId},
      );

      if (shiftResult.isEmpty) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.activeShiftNotFound,
        );
      }

      final shiftRow = shiftResult.single.toColumnMap();

      final shiftId = shiftRow['shift_id'] as String;
      final vehicleId = shiftRow['vehicle_id'] as String;
      final availability = shiftRow['availability'] as String;
      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;

      if (availability != 'available') {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.driverNotAvailable,
        );
      }

      final activeSessionResult = await transaction.execute(
        Sql.named('''
          SELECT id
          FROM external_ride_sessions
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          LIMIT 1
          FOR UPDATE
        '''),
        parameters: {'driverId': driverId},
      );

      if (activeSessionResult.isNotEmpty) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.activeExternalRideExists,
        );
      }

      final pendingOfferResult = await transaction.execute(
        Sql.named('''
          SELECT
            id,
            ride_id,
            expires_at
          FROM ride_offers
          WHERE driver_id = @driverId
            AND vehicle_id = @vehicleId
            AND status = 'pending'
          ORDER BY offered_at ASC
          FOR UPDATE
        '''),
        parameters: {'driverId': driverId, 'vehicleId': vehicleId},
      );

      if (pendingOfferResult.length > 1) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.queueStateMismatch,
        );
      }

      final hasDatabasePendingOffer = pendingOfferResult.isNotEmpty;

      if (hasPendingOffer != hasDatabasePendingOffer) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.queueStateMismatch,
        );
      }

      var offerResolution = AtomicExternalRideStartOfferResolution.none;

      String? resolvedOfferId;
      String? resolvedRideId;

      String? triggerOfferId;
      String? triggerRideId;

      if (pendingOfferResult.isNotEmpty) {
        final offerRow = pendingOfferResult.single.toColumnMap();

        final offerId = offerRow['id'] as String;
        final rideId = offerRow['ride_id'] as String;
        final expiresAt = (offerRow['expires_at'] as DateTime).toUtc();

        resolvedOfferId = offerId;
        resolvedRideId = rideId;

        if (nowUtc.isBefore(expiresAt)) {
          final updateOfferResult = await transaction.execute(
            Sql.named('''
              UPDATE ride_offers
              SET
                status = 'rejected',
                resolved_at = @resolvedAt
              WHERE id = @offerId
                AND status = 'pending'
              RETURNING id
            '''),
            parameters: {'offerId': offerId, 'resolvedAt': nowUtc},
          );

          if (updateOfferResult.isEmpty) {
            throw const AtomicExternalRideConflictException(
              AtomicExternalRideConflict.queueStateMismatch,
            );
          }

          offerResolution = AtomicExternalRideStartOfferResolution.becameBusy;

          triggerOfferId = offerId;
          triggerRideId = rideId;
        } else {
          final updateOfferResult = await transaction.execute(
            Sql.named('''
              UPDATE ride_offers
              SET
                status = 'expired',
                resolved_at = @resolvedAt
              WHERE id = @offerId
                AND status = 'pending'
              RETURNING id
            '''),
            parameters: {'offerId': offerId, 'resolvedAt': nowUtc},
          );

          if (updateOfferResult.isEmpty) {
            throw const AtomicExternalRideConflictException(
              AtomicExternalRideConflict.queueStateMismatch,
            );
          }

          offerResolution = AtomicExternalRideStartOfferResolution.expired;
        }
      }

      final queueUpdateResult = await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET
            availability = 'externalRide',
            break_started_at = NULL,
            has_pending_offer = FALSE
          WHERE shift_id = @shiftId
            AND availability = 'available'
          RETURNING shift_id
        '''),
        parameters: {'shiftId': shiftId},
      );

      if (queueUpdateResult.isEmpty) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.queueStateMismatch,
        );
      }

      final sessionResult = await transaction.execute(
        Sql.named('''
          INSERT INTO external_ride_sessions (
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
          )
          VALUES (
            @id,
            @driverId,
            @startedAt,
            NULL,
            0,
            @triggerOfferId,
            @triggerRideId
          )
          RETURNING
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
        '''),
        parameters: {
          'id': sessionId,
          'driverId': driverId,
          'startedAt': nowUtc,
          'triggerOfferId': triggerOfferId,
          'triggerRideId': triggerRideId,
        },
      );

      final session = _sessionFromRow(sessionResult.single.toColumnMap());

      return AtomicExternalRideStartResult(
        session: session,
        offerResolution: offerResolution,
        resolvedOfferId: resolvedOfferId,
        resolvedRideId: resolvedRideId,
      );
    });
  }

  @override
  Future<AtomicExternalRideFinishResult> finishExternalRide({
    required String driverId,
    required DateTime now,
  }) {
    final nowUtc = now.toUtc();

    return database.runTx((transaction) async {
      final shiftResult = await transaction.execute(
        Sql.named('''
          SELECT
            s.id AS shift_id,
            s.vehicle_id,
            q.availability,
            q.has_pending_offer
          FROM driver_shifts s
          JOIN driver_queue_states q
            ON q.shift_id = s.id
          WHERE s.driver_id = @driverId
            AND s.ended_at IS NULL
          LIMIT 1
          FOR UPDATE OF s, q
        '''),
        parameters: {'driverId': driverId},
      );

      if (shiftResult.isEmpty) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.activeShiftNotFound,
        );
      }

      final shiftRow = shiftResult.single.toColumnMap();

      final shiftId = shiftRow['shift_id'] as String;
      final vehicleId = shiftRow['vehicle_id'] as String;
      final availability = shiftRow['availability'] as String;
      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;

      if (availability != 'externalRide') {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.driverNotOnExternalRide,
        );
      }

      if (hasPendingOffer) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.queueStateMismatch,
        );
      }

      final sessionResult = await transaction.execute(
        Sql.named('''
          SELECT
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
          FROM external_ride_sessions
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          LIMIT 1
          FOR UPDATE
        '''),
        parameters: {'driverId': driverId},
      );

      if (sessionResult.isEmpty) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.activeExternalRideNotFound,
        );
      }

      final currentSession = _sessionFromRow(
        sessionResult.single.toColumnMap(),
      );

      //
      // While shift + queue + external session are locked,
      // check whether this driver already owns a reserved next ride.
      //
      // If one exists, finishing the external ride must promote it
      // directly to the current accepted City6 ride. The driver must
      // never pass through availability=available.
      //
      final reservationResult = await transaction.execute(
        Sql.named('''
          SELECT
            id,
            ride_id,
            driver_id,
            vehicle_id,
            shift_id,
            reserved_at,
            ended_at
          FROM ride_reservations
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          FOR UPDATE
        '''),
        parameters: {'driverId': driverId},
      );

      if (reservationResult.length > 1) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.queueStateMismatch,
        );
      }

      final activeReservation = reservationResult.isEmpty
          ? null
          : reservationResult.single.toColumnMap();

      String? reservedRideId;
      String? reservationId;

      if (activeReservation != null) {
        final reservationDriverId = activeReservation['driver_id'] as String;
        final reservationVehicleId = activeReservation['vehicle_id'] as String;
        final reservationShiftId = activeReservation['shift_id'] as String;

        if (reservationDriverId != driverId ||
            reservationVehicleId != vehicleId ||
            reservationShiftId != shiftId) {
          throw const AtomicExternalRideConflictException(
            AtomicExternalRideConflict.queueStateMismatch,
          );
        }

        reservationId = activeReservation['id'] as String;
        reservedRideId = activeReservation['ride_id'] as String;

        final reservedRideResult = await transaction.execute(
          Sql.named('''
            SELECT
              status,
              assigned_driver_id,
              assigned_vehicle_id
            FROM rides
            WHERE id = @rideId
            FOR UPDATE
          '''),
          parameters: {'rideId': reservedRideId},
        );

        if (reservedRideResult.isEmpty) {
          throw const AtomicExternalRideConflictException(
            AtomicExternalRideConflict.queueStateMismatch,
          );
        }

        final reservedRideRow = reservedRideResult.single.toColumnMap();

        if (reservedRideRow['status'] != 'reserved' ||
            reservedRideRow['assigned_driver_id'] != null ||
            reservedRideRow['assigned_vehicle_id'] != null) {
          throw const AtomicExternalRideConflictException(
            AtomicExternalRideConflict.queueStateMismatch,
          );
        }
      }

      final finishedSession = currentSession.finish(nowUtc);

      final finishSessionResult = await transaction.execute(
        Sql.named('''
          UPDATE external_ride_sessions
          SET ended_at = @endedAt
          WHERE id = @sessionId
            AND ended_at IS NULL
          RETURNING
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
        '''),
        parameters: {'sessionId': finishedSession.id, 'endedAt': nowUtc},
      );

      if (finishSessionResult.isEmpty) {
        throw const AtomicExternalRideConflictException(
          AtomicExternalRideConflict.activeExternalRideNotFound,
        );
      }

      if (activeReservation != null) {
        final rideUpdateResult = await transaction.execute(
          Sql.named('''
            UPDATE rides
            SET
              status = 'accepted',
              assigned_driver_id = @driverId,
              assigned_vehicle_id = @vehicleId
            WHERE id = @rideId
              AND status = 'reserved'
              AND assigned_driver_id IS NULL
              AND assigned_vehicle_id IS NULL
            RETURNING id
          '''),
          parameters: {
            'rideId': reservedRideId,
            'driverId': driverId,
            'vehicleId': vehicleId,
          },
        );

        if (rideUpdateResult.isEmpty) {
          throw const AtomicExternalRideConflictException(
            AtomicExternalRideConflict.queueStateMismatch,
          );
        }

        final reservationUpdateResult = await transaction.execute(
          Sql.named('''
            UPDATE ride_reservations
            SET ended_at = @endedAt
            WHERE id = @reservationId
              AND ended_at IS NULL
            RETURNING id
          '''),
          parameters: {'reservationId': reservationId, 'endedAt': nowUtc},
        );

        if (reservationUpdateResult.isEmpty) {
          throw const AtomicExternalRideConflictException(
            AtomicExternalRideConflict.queueStateMismatch,
          );
        }

        final queueUpdateResult = await transaction.execute(
          Sql.named('''
            UPDATE driver_queue_states
            SET
              availability = 'busy',
              break_started_at = NULL,
              has_pending_offer = FALSE
            WHERE shift_id = @shiftId
              AND availability = 'externalRide'
              AND has_pending_offer = FALSE
            RETURNING shift_id
          '''),
          parameters: {'shiftId': shiftId},
        );

        if (queueUpdateResult.isEmpty) {
          throw const AtomicExternalRideConflictException(
            AtomicExternalRideConflict.queueStateMismatch,
          );
        }
      } else {
        final queueUpdateResult = await transaction.execute(
          Sql.named('''
            UPDATE driver_queue_states
            SET
              availability = 'available',
              queue_priority_since = @queuePrioritySince,
              break_started_at = NULL,
              has_pending_offer = FALSE
            WHERE shift_id = @shiftId
              AND availability = 'externalRide'
              AND has_pending_offer = FALSE
            RETURNING shift_id
          '''),
          parameters: {'shiftId': shiftId, 'queuePrioritySince': nowUtc},
        );

        if (queueUpdateResult.isEmpty) {
          throw const AtomicExternalRideConflictException(
            AtomicExternalRideConflict.queueStateMismatch,
          );
        }
      }

      final restoredFinishedSession = _sessionFromRow(
        finishSessionResult.single.toColumnMap(),
      );

      final shouldCountTriggeredOfferAsRejection =
          restoredFinishedSession.wasTriggeredByPendingOffer &&
          restoredFinishedSession.distanceMeters <
              ExternalRideSession.qualificationDistanceMeters;

      return AtomicExternalRideFinishResult(
        session: restoredFinishedSession,
        shouldCountTriggeredOfferAsRejection:
            shouldCountTriggeredOfferAsRejection,
        triggerOfferId: restoredFinishedSession.triggerOfferId,
        triggerRideId: restoredFinishedSession.triggerRideId,
      );
    });
  }

  ExternalRideSession _sessionFromRow(Map<String, dynamic> row) {
    return ExternalRideSession.restore(
      id: row['id'] as String,
      driverId: row['driver_id'] as String,
      startedAt: (row['started_at'] as DateTime).toUtc(),
      endedAt: (row['ended_at'] as DateTime?)?.toUtc(),
      distanceMeters: row['distance_meters'] as int,
      triggerOfferId: row['trigger_offer_id'] as String?,
      triggerRideId: row['trigger_ride_id'] as String?,
    );
  }
}

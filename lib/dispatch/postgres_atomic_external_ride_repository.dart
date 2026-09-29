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
      //
      // Заключваме активната смяна и queue state-а.
      //
      // Това е същият ред, който automatic offer логиката трябва
      // да заключи преди да даде нова оферта.
      //
      // Ако "Зает" спечели race-а:
      //   availability става externalRide
      //   и новата offer ще бъде отказана от backend-а.
      //
      // Ако offer спечели race-а:
      //   тук ще я видим като pending и ще я приключим коректно.
      //
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

      //
      // Проверяваме истинската pending offer в базата, вместо да
      // разчитаме само на q.has_pending_offer.
      //
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
          //
          // Офертата още е валидна.
          //
          // "Зает" я приключва, но ExternalRideSession пази
          // връзката към нея. По-късно 500-метровото правило ще
          // реши дали това трябва да се отчете като отказ.
          //
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
          //
          // Офертата вече е изтекла.
          //
          // Не позволяваме натискането на "Зает" да превърне
          // timeout-а в external-ride изключение.
          //
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

      final session = ExternalRideSession.restore(
        id: sessionResult.single[0] as String,
        driverId: sessionResult.single[1] as String,
        startedAt: (sessionResult.single[2] as DateTime).toUtc(),
        endedAt: (sessionResult.single[3] as DateTime?)?.toUtc(),
        distanceMeters: sessionResult.single[4] as int,
        triggerOfferId: sessionResult.single[5] as String?,
        triggerRideId: sessionResult.single[6] as String?,
      );

      return AtomicExternalRideStartResult(
        session: session,
        offerResolution: offerResolution,
        resolvedOfferId: resolvedOfferId,
        resolvedRideId: resolvedRideId,
      );
    });
  }
}

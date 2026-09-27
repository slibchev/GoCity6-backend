import 'package:postgres/postgres.dart';

import 'atomic_ride_offer_repository.dart';
import 'ride_offer.dart';

class PostgresAtomicRideOfferRepository implements AtomicRideOfferRepository {
  final SessionExecutor database;

  PostgresAtomicRideOfferRepository({required this.database});

  @override
  Future<RideOffer> createPendingOffer({
    required RideOffer offer,
    required int maxAttempts,
  }) {
    if (maxAttempts <= 0) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'Maximum attempts must be positive.',
      );
    }

    if (offer.status != RideOfferStatus.pending || offer.resolvedAt != null) {
      throw ArgumentError('Only a pending unresolved offer can be created.');
    }

    return database.runTx((transaction) async {
      // 1. Заключваме поръчката.
      //
      // Това сериализира едновременни опити различни
      // шофьори да получат оферта за една и съща поръчка.
      final rideResult = await transaction.execute(
        Sql.named('''
          SELECT
            status,
            assigned_driver_id,
            assigned_vehicle_id
          FROM rides
          WHERE id = @rideId
          FOR UPDATE
        '''),
        parameters: {'rideId': offer.rideId},
      );

      if (rideResult.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideNotFound,
        );
      }

      final rideRow = rideResult.first.toColumnMap();

      if (rideRow['status'] != 'pending') {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideNotPending,
        );
      }

      if (rideRow['assigned_driver_id'] != null ||
          rideRow['assigned_vehicle_id'] != null) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideAlreadyAssigned,
        );
      }

      // 2. Проверяваме броя вече направени предложения.
      final attemptsResult = await transaction.execute(
        Sql.named('''
          SELECT COUNT(*)
          FROM ride_offers
          WHERE ride_id = @rideId
        '''),
        parameters: {'rideId': offer.rideId},
      );

      final attemptsUsed = attemptsResult.first[0] as int;

      if (attemptsUsed >= maxAttempts) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.maxAttemptsReached,
        );
      }

      // 3. Същата поръчка никога не се предлага
      // повторно на същия шофьор.
      final sameDriverResult = await transaction.execute(
        Sql.named('''
          SELECT 1
          FROM ride_offers
          WHERE ride_id = @rideId
            AND driver_id = @driverId
          LIMIT 1
        '''),
        parameters: {'rideId': offer.rideId, 'driverId': offer.driverId},
      );

      if (sameDriverResult.isNotEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideAlreadyOfferedToDriver,
        );
      }

      // 4. Не допускаме втора pending оферта
      // за същата поръчка.
      final pendingRideResult = await transaction.execute(
        Sql.named('''
          SELECT 1
          FROM ride_offers
          WHERE ride_id = @rideId
            AND status = 'pending'
          LIMIT 1
        '''),
        parameters: {'rideId': offer.rideId},
      );

      if (pendingRideResult.isNotEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideAlreadyHasPendingOffer,
        );
      }

      // 5. Заключваме активната смяна и queue state
      // на шофьора.
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
          FOR UPDATE OF s, q
        '''),
        parameters: {'driverId': offer.driverId},
      );

      if (shiftResult.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverShiftNotFound,
        );
      }

      final shiftRow = shiftResult.first.toColumnMap();

      if (shiftRow['vehicle_id'] != offer.vehicleId) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.vehicleDoesNotMatchShift,
        );
      }

      if (shiftRow['availability'] != 'available') {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverNotAvailable,
        );
      }

      if (shiftRow['has_pending_offer'] as bool) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverAlreadyHasPendingOffer,
        );
      }

      // 6. Записваме самата оферта.
      await transaction.execute(
        Sql.named('''
          INSERT INTO ride_offers (
            id,
            ride_id,
            driver_id,
            vehicle_id,
            eta_seconds,
            distance_meters,
            offered_at,
            expires_at,
            status,
            resolved_at
          )
          VALUES (
            @id,
            @rideId,
            @driverId,
            @vehicleId,
            @etaSeconds,
            @distanceMeters,
            @offeredAt,
            @expiresAt,
            'pending',
            NULL
          )
        '''),
        parameters: {
          'id': offer.id,
          'rideId': offer.rideId,
          'driverId': offer.driverId,
          'vehicleId': offer.vehicleId,
          'etaSeconds': offer.etaSeconds,
          'distanceMeters': offer.distanceMeters,
          'offeredAt': offer.offeredAt.toUtc(),
          'expiresAt': offer.expiresAt.toUtc(),
        },
      );

      // 7. В СЪЩАТА transaction маркираме шофьора,
      // че вече има активна оферта.
      final queueUpdate = await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET has_pending_offer = TRUE
          WHERE shift_id = @shiftId
            AND availability = 'available'
            AND has_pending_offer = FALSE
          RETURNING shift_id
        '''),
        parameters: {'shiftId': shiftRow['shift_id']},
      );

      if (queueUpdate.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverAlreadyHasPendingOffer,
        );
      }

      return offer;
    });
  }
}

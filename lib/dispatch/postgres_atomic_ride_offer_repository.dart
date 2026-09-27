import 'package:postgres/postgres.dart';

import 'atomic_ride_offer_repository.dart';
import 'ride_offer.dart';

class PostgresAtomicRideOfferRepository implements AtomicRideOfferRepository {
  final SessionExecutor database;

  PostgresAtomicRideOfferRepository({required this.database});

  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) {
    if (offer.status != RideOfferStatus.pending || offer.resolvedAt != null) {
      throw ArgumentError('Only a pending unresolved offer can be created.');
    }

    return database.runTx((transaction) async {
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

      // Същата поръчка никога не се предлага
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

      // Само една pending оферта за поръчката
      // в даден момент.
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

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    final nowUtc = now.toUtc();

    return database.runTx((transaction) async {
      final offer = await _lockPendingOffer(transaction, offerId);

      if (!nowUtc.isBefore(offer.expiresAt)) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.offerAlreadyExpired,
        );
      }

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

      final shiftRow = await _lockDriverShift(
        transaction,
        driverId: offer.driverId,
      );

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

      if (shiftRow['has_pending_offer'] != true) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverPendingOfferMissing,
        );
      }

      final accepted = offer.accept(nowUtc);

      await transaction.execute(
        Sql.named('''
          UPDATE ride_offers
          SET
            status = 'accepted',
            resolved_at = @resolvedAt
          WHERE id = @offerId
            AND status = 'pending'
        '''),
        parameters: {'offerId': offer.id, 'resolvedAt': nowUtc},
      );

      final rideUpdate = await transaction.execute(
        Sql.named('''
          UPDATE rides
          SET
            status = 'accepted',
            assigned_driver_id = @driverId,
            assigned_vehicle_id = @vehicleId
          WHERE id = @rideId
            AND status = 'pending'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
          RETURNING id
        '''),
        parameters: {
          'rideId': offer.rideId,
          'driverId': offer.driverId,
          'vehicleId': offer.vehicleId,
        },
      );

      if (rideUpdate.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideAlreadyAssigned,
        );
      }

      final queueUpdate = await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET
            availability = 'busy',
            has_pending_offer = FALSE
          WHERE shift_id = @shiftId
            AND availability = 'available'
            AND has_pending_offer = TRUE
          RETURNING shift_id
        '''),
        parameters: {'shiftId': shiftRow['shift_id']},
      );

      if (queueUpdate.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverPendingOfferMissing,
        );
      }

      return accepted;
    });
  }

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    final nowUtc = now.toUtc();

    return database.runTx((transaction) async {
      final offer = await _lockPendingOffer(transaction, offerId);

      if (!nowUtc.isBefore(offer.expiresAt)) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.offerAlreadyExpired,
        );
      }

      final shiftRow = await _lockDriverShift(
        transaction,
        driverId: offer.driverId,
      );

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

      if (shiftRow['has_pending_offer'] != true) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverPendingOfferMissing,
        );
      }

      final rejected = offer.reject(nowUtc);

      await transaction.execute(
        Sql.named('''
          UPDATE ride_offers
          SET
            status = 'rejected',
            resolved_at = @resolvedAt
          WHERE id = @offerId
            AND status = 'pending'
        '''),
        parameters: {'offerId': offer.id, 'resolvedAt': nowUtc},
      );

      final queueUpdate = await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET
            has_pending_offer = FALSE,
            queue_priority_since = @queuePrioritySince
          WHERE shift_id = @shiftId
            AND availability = 'available'
            AND has_pending_offer = TRUE
          RETURNING shift_id
        '''),
        parameters: {
          'shiftId': shiftRow['shift_id'],
          'queuePrioritySince': nowUtc,
        },
      );

      if (queueUpdate.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverPendingOfferMissing,
        );
      }

      return rejected;
    });
  }

  @override
  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  }) {
    final nowUtc = now.toUtc();

    return database.runTx((transaction) async {
      final offer = await _lockPendingOffer(transaction, offerId);

      if (nowUtc.isBefore(offer.expiresAt)) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.offerNotExpiredYet,
        );
      }

      final shiftRow = await _lockDriverShift(
        transaction,
        driverId: offer.driverId,
      );

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

      if (shiftRow['has_pending_offer'] != true) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverPendingOfferMissing,
        );
      }

      final expired = offer.expire(nowUtc);

      await transaction.execute(
        Sql.named('''
          UPDATE ride_offers
          SET
            status = 'expired',
            resolved_at = @resolvedAt
          WHERE id = @offerId
            AND status = 'pending'
        '''),
        parameters: {'offerId': offer.id, 'resolvedAt': nowUtc},
      );

      final queueUpdate = await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET
            has_pending_offer = FALSE,
            queue_priority_since = @queuePrioritySince
          WHERE shift_id = @shiftId
            AND availability = 'available'
            AND has_pending_offer = TRUE
          RETURNING shift_id
        '''),
        parameters: {
          'shiftId': shiftRow['shift_id'],
          'queuePrioritySince': nowUtc,
        },
      );

      if (queueUpdate.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.driverPendingOfferMissing,
        );
      }

      return expired;
    });
  }

  @override
  Future<void> movePendingRideToWaitingForVehicle({required String rideId}) {
    return database.runTx((transaction) async {
      // Заключваме ride реда. createPendingOffer() също започва
      // със заключване на същия ред, така че нова автоматична
      // оферта не може да бъде създадена едновременно с fallback-а.
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
        parameters: {'rideId': rideId},
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

      // Не пращаме поръчката на общия плот, докато някой
      // шофьор все още има активна 15-секундна оферта.
      final pendingOfferResult = await transaction.execute(
        Sql.named('''
          SELECT 1
          FROM ride_offers
          WHERE ride_id = @rideId
            AND status = 'pending'
          LIMIT 1
        '''),
        parameters: {'rideId': rideId},
      );

      if (pendingOfferResult.isNotEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideHasPendingOffer,
        );
      }

      final updateResult = await transaction.execute(
        Sql.named('''
          UPDATE rides
          SET status = 'waitingForVehicle'
          WHERE id = @rideId
            AND status = 'pending'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
          RETURNING id
        '''),
        parameters: {'rideId': rideId},
      );

      if (updateResult.isEmpty) {
        throw const AtomicRideOfferConflictException(
          AtomicRideOfferConflict.rideNotPending,
        );
      }
    });
  }

  Future<RideOffer> _lockPendingOffer(
    Session transaction,
    String offerId,
  ) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT
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
        FROM ride_offers
        WHERE id = @offerId
        FOR UPDATE
      '''),
      parameters: {'offerId': offerId},
    );

    if (result.isEmpty) {
      throw const AtomicRideOfferConflictException(
        AtomicRideOfferConflict.offerNotFound,
      );
    }

    final row = result.first.toColumnMap();

    if (row['status'] != 'pending') {
      throw const AtomicRideOfferConflictException(
        AtomicRideOfferConflict.offerNotPending,
      );
    }

    return RideOffer.restore(
      id: row['id'] as String,
      rideId: row['ride_id'] as String,
      driverId: row['driver_id'] as String,
      vehicleId: row['vehicle_id'] as String,
      etaSeconds: row['eta_seconds'] as int,
      distanceMeters: row['distance_meters'] as int,
      offeredAt: (row['offered_at'] as DateTime).toUtc(),
      expiresAt: (row['expires_at'] as DateTime).toUtc(),
      status: RideOfferStatus.pending,
      resolvedAt: null,
    );
  }

  Future<Map<String, dynamic>> _lockDriverShift(
    Session transaction, {
    required String driverId,
  }) async {
    final result = await transaction.execute(
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
      parameters: {'driverId': driverId},
    );

    if (result.isEmpty) {
      throw const AtomicRideOfferConflictException(
        AtomicRideOfferConflict.driverShiftNotFound,
      );
    }

    return result.first.toColumnMap();
  }
}

import 'package:postgres/postgres.dart';

import 'atomic_ride_reservation_repository.dart';
import 'external_ride_session.dart';
import 'ride_reservation.dart';

class PostgresAtomicRideReservationRepository
    implements AtomicRideReservationRepository {
  final SessionExecutor database;

  PostgresAtomicRideReservationRepository({
    required this.database,
  });

  @override
  Future<RideReservation> reserveWaitingRide({
    required String reservationId,
    required String rideId,
    required String driverId,
    required int combinedEtaSeconds,
    required DateTime now,
  }) {
    if (combinedEtaSeconds < 0) {
      throw ArgumentError.value(
        combinedEtaSeconds,
        'combinedEtaSeconds',
        'ETA cannot be negative.',
      );
    }

    if (combinedEtaSeconds >
        AtomicRideReservationRepository.maximumCombinedEtaSeconds) {
      throw const AtomicRideReservationConflictException(
        AtomicRideReservationConflict.etaTooHigh,
      );
    }

    final nowUtc = now.toUtc();

    return database.runTx((transaction) async {
      // ------------------------------------------------------------
      // 1. Lock target waiting ride first.
      //
      // This serializes two drivers racing for the same board ride.
      // ------------------------------------------------------------
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
        parameters: {
          'rideId': rideId,
        },
      );

      if (rideResult.isEmpty) {
        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.rideNotFound,
        );
      }

      final rideRow = rideResult.single.toColumnMap();

      if (rideRow['status'] != 'waitingForVehicle') {
        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.rideNotWaitingForVehicle,
        );
      }

      if (rideRow['assigned_driver_id'] != null ||
          rideRow['assigned_vehicle_id'] != null) {
        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.rideAlreadyAssigned,
        );
      }

      // ------------------------------------------------------------
      // 2. Lock active shift + queue state.
      //
      // This serializes one driver racing to reserve two different
      // waiting rides.
      // ------------------------------------------------------------
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
        parameters: {
          'driverId': driverId,
        },
      );

      if (shiftResult.isEmpty) {
        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.activeShiftNotFound,
        );
      }

      final shiftRow = shiftResult.single.toColumnMap();

      final shiftId = shiftRow['shift_id'] as String;
      final vehicleId = shiftRow['vehicle_id'] as String;
      final availability = shiftRow['availability'] as String;
      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;

      if (availability != 'busy' && availability != 'externalRide') {
        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.driverNotReservable,
        );
      }

      // A busy/externalRide driver must not simultaneously carry
      // an automatic pending offer.
      if (hasPendingOffer) {
        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.queueStateMismatch,
        );
      }

      // ------------------------------------------------------------
      // 3. Validate the driver's current busy mode atomically.
      // ------------------------------------------------------------
      if (availability == 'busy') {
        final currentRideResult = await transaction.execute(
          Sql.named('''
            SELECT
              id,
              status,
              assigned_driver_id,
              assigned_vehicle_id
            FROM rides
            WHERE assigned_driver_id = @driverId
              AND assigned_vehicle_id = @vehicleId
              AND status IN (
                'accepted',
                'driverArriving',
                'inProgress'
              )
              AND id <> @targetRideId
            ORDER BY requested_at ASC
            FOR UPDATE
          '''),
          parameters: {
            'driverId': driverId,
            'vehicleId': vehicleId,
            'targetRideId': rideId,
          },
        );

        if (currentRideResult.isEmpty) {
          throw const AtomicRideReservationConflictException(
            AtomicRideReservationConflict.currentCity6RideNotFound,
          );
        }

        // queue availability == busy represents one current City6 ride.
        // More than one active assigned ride means persisted state is
        // inconsistent and reservation must not continue.
        if (currentRideResult.length > 1) {
          throw const AtomicRideReservationConflictException(
            AtomicRideReservationConflict.queueStateMismatch,
          );
        }
      } else {
        final sessionResult = await transaction.execute(
          Sql.named('''
            SELECT
              id,
              distance_meters
            FROM external_ride_sessions
            WHERE driver_id = @driverId
              AND ended_at IS NULL
            LIMIT 1
            FOR UPDATE
          '''),
          parameters: {
            'driverId': driverId,
          },
        );

        if (sessionResult.isEmpty) {
          throw const AtomicRideReservationConflictException(
            AtomicRideReservationConflict.activeExternalRideNotFound,
          );
        }

        final sessionRow = sessionResult.single.toColumnMap();
        final distanceMeters = sessionRow['distance_meters'] as int;

        if (distanceMeters <
            ExternalRideSession.qualificationDistanceMeters) {
          throw const AtomicRideReservationConflictException(
            AtomicRideReservationConflict.externalRideNotQualified,
          );
        }
      }

      // ------------------------------------------------------------
      // 4. Check active reservation invariants while locks above are
      // held. DB partial unique indexes remain the final protection.
      // ------------------------------------------------------------
      final reservationResult = await transaction.execute(
        Sql.named('''
          SELECT
            ride_id,
            driver_id,
            vehicle_id
          FROM ride_reservations
          WHERE ended_at IS NULL
            AND (
              ride_id = @rideId
              OR driver_id = @driverId
              OR vehicle_id = @vehicleId
            )
          FOR UPDATE
        '''),
        parameters: {
          'rideId': rideId,
          'driverId': driverId,
          'vehicleId': vehicleId,
        },
      );

      if (reservationResult.isNotEmpty) {
        final rows = reservationResult
            .map((row) => row.toColumnMap())
            .toList();

        final rideAlreadyReserved = rows.any(
          (row) => row['ride_id'] == rideId,
        );

        if (rideAlreadyReserved) {
          throw const AtomicRideReservationConflictException(
            AtomicRideReservationConflict.rideAlreadyReserved,
          );
        }

        final driverAlreadyReserved = rows.any(
          (row) => row['driver_id'] == driverId,
        );

        if (driverAlreadyReserved) {
          throw const AtomicRideReservationConflictException(
            AtomicRideReservationConflict.driverAlreadyHasReservedRide,
          );
        }

        final vehicleAlreadyReserved = rows.any(
          (row) => row['vehicle_id'] == vehicleId,
        );

        if (vehicleAlreadyReserved) {
          throw const AtomicRideReservationConflictException(
            AtomicRideReservationConflict.vehicleAlreadyHasReservedRide,
          );
        }

        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.queueStateMismatch,
        );
      }

      // ------------------------------------------------------------
      // 5. Create reservation.
      //
      // assigned_driver_id / assigned_vehicle_id intentionally remain
      // NULL. Reservation ownership lives in ride_reservations.
      // ------------------------------------------------------------
      final insertResult = await transaction.execute(
        Sql.named('''
          INSERT INTO ride_reservations (
            id,
            ride_id,
            driver_id,
            vehicle_id,
            shift_id,
            reserved_at,
            ended_at
          )
          VALUES (
            @id,
            @rideId,
            @driverId,
            @vehicleId,
            @shiftId,
            @reservedAt,
            NULL
          )
          RETURNING
            id,
            ride_id,
            driver_id,
            vehicle_id,
            shift_id,
            reserved_at,
            ended_at
        '''),
        parameters: {
          'id': reservationId,
          'rideId': rideId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'shiftId': shiftId,
          'reservedAt': nowUtc,
        },
      );

      // ------------------------------------------------------------
      // 6. Move board ride to reserved.
      //
      // No bonus fields are touched, so an existing +5 EUR bonus is
      // preserved unchanged.
      // ------------------------------------------------------------
      final rideUpdateResult = await transaction.execute(
        Sql.named('''
          UPDATE rides
          SET status = 'reserved'
          WHERE id = @rideId
            AND status = 'waitingForVehicle'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
          RETURNING id
        '''),
        parameters: {
          'rideId': rideId,
        },
      );

      if (rideUpdateResult.isEmpty) {
        throw const AtomicRideReservationConflictException(
          AtomicRideReservationConflict.rideNotWaitingForVehicle,
        );
      }

      return _reservationFromRow(
        insertResult.single.toColumnMap(),
      );
    });
  }

  RideReservation _reservationFromRow(
    Map<String, dynamic> row,
  ) {
    return RideReservation.restore(
      id: row['id'] as String,
      rideId: row['ride_id'] as String,
      driverId: row['driver_id'] as String,
      vehicleId: row['vehicle_id'] as String,
      shiftId: row['shift_id'] as String,
      reservedAt: (row['reserved_at'] as DateTime).toUtc(),
      endedAt: (row['ended_at'] as DateTime?)?.toUtc(),
    );
  }
}
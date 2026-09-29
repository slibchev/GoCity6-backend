import 'package:postgres/postgres.dart';



import 'atomic_ride_completion_repository.dart';

import 'ride_request.dart';

import 'ride_request_repository.dart';

import 'ride_request_status.dart';



class PostgresRideRequestRepository

    implements

        RideRequestRepository,

        AtomicRideClaimRepository,

        AtomicRideCompletionRepository {

  final Session database;



  PostgresRideRequestRepository({required this.database});



  @override

  Future<RideRequest?> findById(String id) async {

    final result = await database.execute(

      Sql.named('''

        SELECT

          id,

          pickup,

          destination,

          passengers,

          has_luggage,

          requested_at,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

        FROM rides

        WHERE id = @id

        LIMIT 1

      '''),

      parameters: {'id': id},

    );



    if (result.isEmpty) {

      return null;

    }



    return _rideFromRow(result.first.toColumnMap());

  }



  @override

  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {

    final result = await database.execute(

      Sql.named('''

        SELECT

          id,

          pickup,

          destination,

          passengers,

          has_luggage,

          requested_at,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

        FROM rides

        WHERE assigned_driver_id = @driverId

        ORDER BY requested_at ASC

      '''),

      parameters: {'driverId': driverId},

    );



    return result.map((row) => _rideFromRow(row.toColumnMap())).toList();

  }



  @override

  Future<void> save(RideRequest request) async {

    await database.execute(

      Sql.named('''

        INSERT INTO rides (

          id,

          pickup,

          destination,

          passengers,

          has_luggage,

          requested_at,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

        )

        VALUES (

          @id,

          @pickup,

          @destination,

          @passengers,

          @hasLuggage,

          @requestedAt,

          @status,

          @assignedDriverId,

          @assignedVehicleId,

          @dispatchRound,

          @driverBonusMinor,

          @bonusDecision,

          @currency,

          @meterFareMinor,

          @commissionRateBps,

          @commissionAmountMinor,

          @completedByDriverId,

          @completedAt

        )

        ON CONFLICT (id)

        DO UPDATE SET

          pickup = EXCLUDED.pickup,

          destination = EXCLUDED.destination,

          passengers = EXCLUDED.passengers,

          has_luggage = EXCLUDED.has_luggage,

          requested_at = EXCLUDED.requested_at,

          status = EXCLUDED.status,

          assigned_driver_id = EXCLUDED.assigned_driver_id,

          assigned_vehicle_id = EXCLUDED.assigned_vehicle_id,

          dispatch_round = EXCLUDED.dispatch_round,

          driver_bonus_minor = EXCLUDED.driver_bonus_minor,

          bonus_decision = EXCLUDED.bonus_decision,

          currency = EXCLUDED.currency,

          meter_fare_minor = EXCLUDED.meter_fare_minor,

          commission_rate_bps = EXCLUDED.commission_rate_bps,

          commission_amount_minor = EXCLUDED.commission_amount_minor,

          completed_by_driver_id = EXCLUDED.completed_by_driver_id,

          completed_at = EXCLUDED.completed_at

      '''),

      parameters: {

        'id': request.id,

        'pickup': request.pickup,

        'destination': request.destination,

        'passengers': request.passengers,

        'hasLuggage': request.hasLuggage,

        'requestedAt': request.requestedAt.toUtc(),

        'status': request.status.name,

        'assignedDriverId': request.assignedDriverId,

        'assignedVehicleId': request.assignedVehicleId,

        'dispatchRound': request.dispatchRound,

        'driverBonusMinor': request.driverBonusMinor,

        'bonusDecision': request.bonusDecision.databaseValue,

        'currency': request.currency,

        'meterFareMinor': request.meterFareMinor,

        'commissionRateBps': request.commissionRateBps,

        'commissionAmountMinor': request.commissionAmountMinor,

        'completedByDriverId': request.completedByDriverId,

        'completedAt': request.completedAt?.toUtc(),

      },

    );

  }



  @override

  Future<RideRequest?> claimWaitingRide({

    required String rideId,

    required String driverId,

    required String vehicleId,

    required RideRequestStatus targetStatus,

  }) async {

    if (targetStatus != RideRequestStatus.accepted &&

        targetStatus != RideRequestStatus.reserved) {

      throw ArgumentError.value(

        targetStatus,

        'targetStatus',

        'Target status must be accepted or reserved.',

      );

    }



    final result = await database.execute(

      Sql.named('''

        UPDATE rides

        SET

          status = @status,

          assigned_driver_id = @driverId,

          assigned_vehicle_id = @vehicleId

        WHERE id = @rideId

          AND status = 'waitingForVehicle'

          AND assigned_driver_id IS NULL

          AND assigned_vehicle_id IS NULL

        RETURNING

          id,

          pickup,

          destination,

          passengers,

          has_luggage,

          requested_at,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

      '''),

      parameters: {

        'rideId': rideId,

        'driverId': driverId,

        'vehicleId': vehicleId,

        'status': targetStatus.name,

      },

    );



    if (result.isEmpty) {

      return null;

    }



    return _rideFromRow(result.first.toColumnMap());

  }



  @override

  Future<RideRequest> completeRideAndPromoteReservedRide({

    required RideRequest completedRide,

  }) {

    if (completedRide.status != RideRequestStatus.completed) {

      throw ArgumentError.value(

        completedRide.status,

        'completedRide.status',

        'Ride must already be computed as completed.',

      );

    }



    final driverId = completedRide.completedByDriverId;

    final assignedDriverId = completedRide.assignedDriverId;

    final vehicleId = completedRide.assignedVehicleId;

    final completedAt = completedRide.completedAt?.toUtc();

    final meterFareMinor = completedRide.meterFareMinor;

    final commissionRateBps = completedRide.commissionRateBps;

    final commissionAmountMinor = completedRide.commissionAmountMinor;



    if (driverId == null ||

        assignedDriverId == null ||

        vehicleId == null ||

        completedAt == null ||

        meterFareMinor == null ||

        commissionRateBps == null ||

        commissionAmountMinor == null) {

      throw ArgumentError(

        'Completed ride is missing assignment, fare, commission, '

        'or completion data.',

      );

    }



    if (assignedDriverId != driverId) {

      throw ArgumentError('completedByDriverId must match assignedDriverId.');

    }



    if (meterFareMinor <= 0 ||

        commissionRateBps < 0 ||

        commissionAmountMinor < 0) {

      throw ArgumentError(

        'Completed ride contains invalid fare or commission data.',

      );

    }



    final transactionDatabase = database as SessionExecutor;

    return transactionDatabase.runTx((transaction) async {

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

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.activeShiftNotFound,

        );

      }



      final shiftRow = shiftResult.single.toColumnMap();

      final shiftId = shiftRow['shift_id'] as String;

      final shiftVehicleId = shiftRow['vehicle_id'] as String;

      final availability = shiftRow['availability'] as String;

      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;



      if (shiftVehicleId != vehicleId) {

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.currentRideAssignmentMismatch,

        );

      }



      if (availability != 'busy' || hasPendingOffer) {

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.queueStateMismatch,

        );

      }



      final currentRideResult = await transaction.execute(

        Sql.named('''

          SELECT

            status,

            assigned_driver_id,

            assigned_vehicle_id,

            completed_by_driver_id,

            completed_at

          FROM rides

          WHERE id = @rideId

          FOR UPDATE

        '''),

        parameters: {'rideId': completedRide.id},

      );



      if (currentRideResult.isEmpty) {

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.currentRideNotFound,

        );

      }



      final currentRideRow = currentRideResult.single.toColumnMap();



      if (currentRideRow['status'] != 'inProgress') {

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.currentRideNotInProgress,

        );

      }



      if (currentRideRow['assigned_driver_id'] != driverId ||

          currentRideRow['assigned_vehicle_id'] != vehicleId) {

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.currentRideAssignmentMismatch,

        );

      }



      if (currentRideRow['completed_by_driver_id'] != null ||

          currentRideRow['completed_at'] != null) {

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.currentRideNotInProgress,

        );

      }



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

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.reservationStateMismatch,

        );

      }



      Map<String, dynamic>? reservationRow;

      String? reservationId;

      String? reservedRideId;



      if (reservationResult.isNotEmpty) {

        final activeReservationRow =
            reservationResult.single.toColumnMap();
        reservationRow = activeReservationRow;

        if (activeReservationRow['driver_id'] != driverId ||
            activeReservationRow['vehicle_id'] != vehicleId ||
            activeReservationRow['shift_id'] != shiftId) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.reservationStateMismatch,
          );
        }

        reservationId = activeReservationRow['id'] as String;
        reservedRideId = activeReservationRow['ride_id'] as String;



        if (reservedRideId == completedRide.id) {

          throw const AtomicRideCompletionConflictException(

            AtomicRideCompletionConflict.reservationStateMismatch,

          );

        }



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

          throw const AtomicRideCompletionConflictException(

            AtomicRideCompletionConflict.reservedRideStateMismatch,

          );

        }



        final reservedRideRow = reservedRideResult.single.toColumnMap();



        if (reservedRideRow['status'] != 'reserved' ||

            reservedRideRow['assigned_driver_id'] != null ||

            reservedRideRow['assigned_vehicle_id'] != null) {

          throw const AtomicRideCompletionConflictException(

            AtomicRideCompletionConflict.reservedRideStateMismatch,

          );

        }

      }



      final completedRideResult = await transaction.execute(

        Sql.named('''

          UPDATE rides

          SET

            status = 'completed',

            meter_fare_minor = @meterFareMinor,

            commission_rate_bps = @commissionRateBps,

            commission_amount_minor = @commissionAmountMinor,

            completed_by_driver_id = @completedByDriverId,

            completed_at = @completedAt

          WHERE id = @rideId

            AND status = 'inProgress'

            AND assigned_driver_id = @driverId

            AND assigned_vehicle_id = @vehicleId

            AND completed_by_driver_id IS NULL

            AND completed_at IS NULL

          RETURNING

            id,

            pickup,

            destination,

            passengers,

            has_luggage,

            requested_at,

            status,

            assigned_driver_id,

            assigned_vehicle_id,

            dispatch_round,

            driver_bonus_minor,

            bonus_decision,

            currency,

            meter_fare_minor,

            commission_rate_bps,

            commission_amount_minor,

            completed_by_driver_id,

            completed_at

        '''),

        parameters: {

          'rideId': completedRide.id,

          'driverId': driverId,

          'vehicleId': vehicleId,

          'meterFareMinor': meterFareMinor,

          'commissionRateBps': commissionRateBps,

          'commissionAmountMinor': commissionAmountMinor,

          'completedByDriverId': driverId,

          'completedAt': completedAt,

        },

      );



      if (completedRideResult.isEmpty) {

        throw const AtomicRideCompletionConflictException(

          AtomicRideCompletionConflict.currentRideNotInProgress,

        );

      }



      if (reservationRow != null) {

        final reservedRideUpdateResult = await transaction.execute(

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



        if (reservedRideUpdateResult.isEmpty) {

          throw const AtomicRideCompletionConflictException(

            AtomicRideCompletionConflict.reservedRideStateMismatch,

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

          parameters: {'reservationId': reservationId, 'endedAt': completedAt},

        );



        if (reservationUpdateResult.isEmpty) {

          throw const AtomicRideCompletionConflictException(

            AtomicRideCompletionConflict.reservationStateMismatch,

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

              AND availability = 'busy'

              AND has_pending_offer = FALSE

            RETURNING shift_id

          '''),

          parameters: {'shiftId': shiftId},

        );



        if (queueUpdateResult.isEmpty) {

          throw const AtomicRideCompletionConflictException(

            AtomicRideCompletionConflict.queueStateMismatch,

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

              AND availability = 'busy'

              AND has_pending_offer = FALSE

            RETURNING shift_id

          '''),

          parameters: {'shiftId': shiftId, 'queuePrioritySince': completedAt},

        );



        if (queueUpdateResult.isEmpty) {

          throw const AtomicRideCompletionConflictException(

            AtomicRideCompletionConflict.queueStateMismatch,

          );

        }

      }



      return _rideFromRow(completedRideResult.single.toColumnMap());

    });

  }



  RideRequest _rideFromRow(Map<String, dynamic> row) {

    return RideRequest(

      id: row['id'] as String,

      pickup: row['pickup'] as String,

      destination: row['destination'] as String,

      passengers: row['passengers'] as int,

      hasLuggage: row['has_luggage'] as bool,

      requestedAt: (row['requested_at'] as DateTime).toUtc(),

      status: RideRequestStatus.values.byName(row['status'] as String),

      assignedDriverId: row['assigned_driver_id'] as String?,

      assignedVehicleId: row['assigned_vehicle_id'] as String?,

      dispatchRound: row['dispatch_round'] as int,

      driverBonusMinor: row['driver_bonus_minor'] as int,

      bonusDecision: RideBonusDecision.fromDatabaseValue(

        row['bonus_decision'] as String,

      ),

      currency: (row['currency'] as String).trim(),

      meterFareMinor: row['meter_fare_minor'] as int?,

      commissionRateBps: row['commission_rate_bps'] as int?,

      commissionAmountMinor: row['commission_amount_minor'] as int?,

      completedByDriverId: row['completed_by_driver_id'] as String?,

      completedAt: (row['completed_at'] as DateTime?)?.toUtc(),

    );

  }

}

import 'package:postgres/postgres.dart';

import '../ride/ride_request.dart';
import '../ride/ride_request_status.dart';
import 'atomic_waiting_ride_acceptance_repository.dart';

class PostgresAtomicWaitingRideAcceptanceRepository
    implements AtomicWaitingRideAcceptanceRepository {
  final SessionExecutor database;

  PostgresAtomicWaitingRideAcceptanceRepository({
    required this.database,
  });

  @override
  Future<RideRequest> acceptWaitingRide({
    required String rideId,
    required String driverId,
  }) {
    return database.runTx((transaction) async {
      final rideResult = await transaction.execute(
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
          WHERE id = @rideId
          FOR UPDATE
        '''),
        parameters: {
          'rideId': rideId,
        },
      );

      if (rideResult.isEmpty) {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.rideNotFound,
        );
      }

      final rideRow = rideResult.single.toColumnMap();

      if (rideRow['status'] != 'waitingForVehicle') {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.rideNotWaitingForVehicle,
        );
      }

      if (rideRow['assigned_driver_id'] != null ||
          rideRow['assigned_vehicle_id'] != null) {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.rideAlreadyAssigned,
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
          LIMIT 1
          FOR UPDATE OF s, q
        '''),
        parameters: {
          'driverId': driverId,
        },
      );

      if (shiftResult.isEmpty) {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.activeShiftNotFound,
        );
      }

      final shiftRow = shiftResult.single.toColumnMap();
      final shiftId = shiftRow['shift_id'] as String;
      final vehicleId = shiftRow['vehicle_id'] as String;
      final availability = shiftRow['availability'] as String;
      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;

      if (availability != 'available') {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.driverNotAvailable,
        );
      }

      if (hasPendingOffer) {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.pendingOfferExists,
        );
      }

      final acceptedRideResult = await transaction.execute(
        Sql.named('''
          UPDATE rides
          SET
            status = 'accepted',
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
        },
      );

      if (acceptedRideResult.isEmpty) {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.rideNotWaitingForVehicle,
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
            AND availability = 'available'
            AND has_pending_offer = FALSE
          RETURNING shift_id
        '''),
        parameters: {
          'shiftId': shiftId,
        },
      );

      if (queueUpdateResult.isEmpty) {
        throw const AtomicWaitingRideAcceptanceConflictException(
          AtomicWaitingRideAcceptanceConflict.queueStateMismatch,
        );
      }

      return _rideFromRow(
        acceptedRideResult.single.toColumnMap(),
      );
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
      status: RideRequestStatus.values.byName(
        row['status'] as String,
      ),
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

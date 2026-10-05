import 'package:postgres/postgres.dart';

import '../ride/ride_request.dart';
import '../ride/ride_request_status.dart';
import 'active_driver_shift.dart';
import 'driver_queue_state.dart';
import 'driver_work_state_repository.dart';
import 'ride_offer.dart';

class PostgresDriverWorkStateRepository
    implements DriverWorkStateRepository {
  final SessionExecutor database;

  PostgresDriverWorkStateRepository({
    required this.database,
  });

  @override
  Future<DriverWorkStateSnapshot> loadByDriverId(
    String driverId,
  ) {
    return database.run((session) async {
      final shiftResult = await session.execute(
        Sql.named('''
          SELECT
            s.id AS shift_id,
            s.driver_id,
            s.vehicle_id,
            s.started_at,
            s.protected_breaks_used,
            q.availability,
            q.queue_priority_since,
            q.break_started_at,
            q.has_pending_offer
          FROM driver_shifts s
          JOIN driver_queue_states q
            ON q.shift_id = s.id
          WHERE s.driver_id = @driverId
            AND s.ended_at IS NULL
          LIMIT 2
        '''),
        parameters: {
          'driverId': driverId,
        },
      );

      if (shiftResult.length > 1) {
        throw StateError(
          'Driver has more than one active shift.',
        );
      }

      if (shiftResult.isEmpty) {
        return const DriverWorkStateSnapshot(
          activeShift: null,
          pendingOffer: null,
          currentRide: null,
          reservedRide: null,
        );
      }

      final shift =
          _shiftFromRow(shiftResult.single.toColumnMap());

      final pendingOfferResult = await session.execute(
        Sql.named('''
          SELECT
            o.id AS offer_id,
            o.ride_id AS offer_ride_id,
            o.driver_id AS offer_driver_id,
            o.vehicle_id AS offer_vehicle_id,
            o.eta_seconds AS offer_eta_seconds,
            o.distance_meters AS offer_distance_meters,
            o.dispatch_round AS offer_dispatch_round,
            o.bonus_minor AS offer_bonus_minor,
            o.offered_at AS offer_offered_at,
            o.expires_at AS offer_expires_at,
            o.status AS offer_status,
            o.resolved_at AS offer_resolved_at,

            r.id AS ride_id,
            r.pickup AS ride_pickup,
            r.destination AS ride_destination,
            r.passengers AS ride_passengers,
            r.has_luggage AS ride_has_luggage,
            r.requested_at AS ride_requested_at,
            r.status AS ride_status,
            r.assigned_driver_id AS ride_assigned_driver_id,
            r.assigned_vehicle_id AS ride_assigned_vehicle_id,
            r.dispatch_round AS ride_dispatch_round,
            r.driver_bonus_minor AS ride_driver_bonus_minor,
            r.bonus_decision AS ride_bonus_decision,
            r.currency AS ride_currency,
            r.meter_fare_minor AS ride_meter_fare_minor,
            r.commission_rate_bps AS ride_commission_rate_bps,
            r.commission_amount_minor AS ride_commission_amount_minor,
            r.completed_by_driver_id AS ride_completed_by_driver_id,
            r.completed_at AS ride_completed_at
          FROM ride_offers o
          JOIN rides r
            ON r.id = o.ride_id
          WHERE o.driver_id = @driverId
            AND o.status = 'pending'
          ORDER BY o.offered_at DESC
          LIMIT 2
        '''),
        parameters: {
          'driverId': driverId,
        },
      );

      if (pendingOfferResult.length > 1) {
        throw StateError(
          'Driver has more than one pending offer.',
        );
      }

      DriverPendingOfferState? pendingOffer;

      if (pendingOfferResult.isNotEmpty) {
        final row =
            pendingOfferResult.single.toColumnMap();

        pendingOffer = DriverPendingOfferState(
          offer: _offerFromRow(row),
          ride: _rideFromRow(row),
        );
      }

      final currentRideResult = await session.execute(
        Sql.named('''
          SELECT
            r.id AS ride_id,
            r.pickup AS ride_pickup,
            r.destination AS ride_destination,
            r.passengers AS ride_passengers,
            r.has_luggage AS ride_has_luggage,
            r.requested_at AS ride_requested_at,
            r.status AS ride_status,
            r.assigned_driver_id AS ride_assigned_driver_id,
            r.assigned_vehicle_id AS ride_assigned_vehicle_id,
            r.dispatch_round AS ride_dispatch_round,
            r.driver_bonus_minor AS ride_driver_bonus_minor,
            r.bonus_decision AS ride_bonus_decision,
            r.currency AS ride_currency,
            r.meter_fare_minor AS ride_meter_fare_minor,
            r.commission_rate_bps AS ride_commission_rate_bps,
            r.commission_amount_minor AS ride_commission_amount_minor,
            r.completed_by_driver_id AS ride_completed_by_driver_id,
            r.completed_at AS ride_completed_at
          FROM rides r
          WHERE r.assigned_driver_id = @driverId
            AND r.status IN (
              'accepted',
              'driverArriving',
              'inProgress'
            )
          ORDER BY r.requested_at ASC
          LIMIT 2
        '''),
        parameters: {
          'driverId': driverId,
        },
      );

      if (currentRideResult.length > 1) {
        throw StateError(
          'Driver has more than one current City6 ride.',
        );
      }

      final currentRide = currentRideResult.isEmpty
          ? null
          : _rideFromRow(
              currentRideResult.single.toColumnMap(),
            );

      final reservedRideResult = await session.execute(
        Sql.named('''
          SELECT
            r.id AS ride_id,
            r.pickup AS ride_pickup,
            r.destination AS ride_destination,
            r.passengers AS ride_passengers,
            r.has_luggage AS ride_has_luggage,
            r.requested_at AS ride_requested_at,
            r.status AS ride_status,
            r.assigned_driver_id AS ride_assigned_driver_id,
            r.assigned_vehicle_id AS ride_assigned_vehicle_id,
            r.dispatch_round AS ride_dispatch_round,
            r.driver_bonus_minor AS ride_driver_bonus_minor,
            r.bonus_decision AS ride_bonus_decision,
            r.currency AS ride_currency,
            r.meter_fare_minor AS ride_meter_fare_minor,
            r.commission_rate_bps AS ride_commission_rate_bps,
            r.commission_amount_minor AS ride_commission_amount_minor,
            r.completed_by_driver_id AS ride_completed_by_driver_id,
            r.completed_at AS ride_completed_at
          FROM ride_reservations rr
          JOIN rides r
            ON r.id = rr.ride_id
          WHERE rr.driver_id = @driverId
            AND rr.ended_at IS NULL
            AND r.status = 'reserved'
          ORDER BY rr.reserved_at DESC
          LIMIT 2
        '''),
        parameters: {
          'driverId': driverId,
        },
      );

      if (reservedRideResult.length > 1) {
        throw StateError(
          'Driver has more than one active reserved ride.',
        );
      }

      final reservedRide = reservedRideResult.isEmpty
          ? null
          : _rideFromRow(
              reservedRideResult.single.toColumnMap(),
            );

      return DriverWorkStateSnapshot(
        activeShift: shift,
        pendingOffer: pendingOffer,
        currentRide: currentRide,
        reservedRide: reservedRide,
      );
    });
  }

  ActiveDriverShift _shiftFromRow(
    Map<String, dynamic> row,
  ) {
    final driverId = row['driver_id'] as String;

    final queueState = DriverQueueState.restore(
      driverId: driverId,
      queuePrioritySince:
          (row['queue_priority_since'] as DateTime)
              .toUtc(),
      availability:
          DriverQueueAvailability.values.byName(
        row['availability'] as String,
      ),
      shortBreaksUsed:
          row['protected_breaks_used'] as int,
      breakStartedAt:
          (row['break_started_at'] as DateTime?)
              ?.toUtc(),
      hasPendingOffer:
          row['has_pending_offer'] as bool,
    );

    return ActiveDriverShift.restore(
      id: row['shift_id'] as String,
      driverId: driverId,
      vehicleId: row['vehicle_id'] as String,
      startedAt:
          (row['started_at'] as DateTime).toUtc(),
      queueState: queueState,
    );
  }

  RideOffer _offerFromRow(
    Map<String, dynamic> row,
  ) {
    return RideOffer.restore(
      id: row['offer_id'] as String,
      rideId: row['offer_ride_id'] as String,
      driverId: row['offer_driver_id'] as String,
      vehicleId:
          row['offer_vehicle_id'] as String,
      etaSeconds:
          row['offer_eta_seconds'] as int,
      distanceMeters:
          row['offer_distance_meters'] as int,
      dispatchRound:
          row['offer_dispatch_round'] as int,
      bonusMinor:
          row['offer_bonus_minor'] as int,
      offeredAt:
          (row['offer_offered_at'] as DateTime)
              .toUtc(),
      expiresAt:
          (row['offer_expires_at'] as DateTime)
              .toUtc(),
      status: RideOfferStatus.values.byName(
        row['offer_status'] as String,
      ),
      resolvedAt:
          (row['offer_resolved_at'] as DateTime?)
              ?.toUtc(),
    );
  }

  RideRequest _rideFromRow(
    Map<String, dynamic> row,
  ) {
    return RideRequest(
      id: row['ride_id'] as String,
      pickup: row['ride_pickup'] as String,
      destination:
          row['ride_destination'] as String,
      passengers:
          row['ride_passengers'] as int,
      hasLuggage:
          row['ride_has_luggage'] as bool,
      requestedAt:
          (row['ride_requested_at'] as DateTime)
              .toUtc(),
      status: RideRequestStatus.values.byName(
        row['ride_status'] as String,
      ),
      assignedDriverId:
          row['ride_assigned_driver_id'] as String?,
      assignedVehicleId:
          row['ride_assigned_vehicle_id'] as String?,
      dispatchRound:
          row['ride_dispatch_round'] as int,
      driverBonusMinor:
          row['ride_driver_bonus_minor'] as int,
      bonusDecision:
          RideBonusDecision.fromDatabaseValue(
        row['ride_bonus_decision'] as String,
      ),
      currency:
          (row['ride_currency'] as String).trim(),
      meterFareMinor:
          row['ride_meter_fare_minor'] as int?,
      commissionRateBps:
          row['ride_commission_rate_bps'] as int?,
      commissionAmountMinor:
          row['ride_commission_amount_minor'] as int?,
      completedByDriverId:
          row['ride_completed_by_driver_id']
              as String?,
      completedAt:
          (row['ride_completed_at'] as DateTime?)
              ?.toUtc(),
    );
  }
}
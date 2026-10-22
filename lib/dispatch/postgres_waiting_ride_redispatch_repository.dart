import 'package:postgres/postgres.dart';

import '../ride/ride_request.dart';
import '../ride/ride_request_status.dart';
import 'waiting_ride_redispatch_repository.dart';

class PostgresWaitingRideRedispatchRepository
    implements WaitingRideRedispatchRepository {
  final Session database;

  PostgresWaitingRideRedispatchRepository({required this.database});

  @override
  Future<List<RideRequest>> findOldestPage({
    required DateTime notBefore,
    DateTime? afterRequestedAt,
    String? afterRideId,
    int limit = 50,
  }) async {
    if (limit <= 0 || limit > 200) {
      throw ArgumentError.value(limit, 'limit', 'Limit must be 1 through 200.');
    }

    if ((afterRequestedAt == null) != (afterRideId == null)) {
      throw ArgumentError('Both cursor fields must be provided together.');
    }

    final cursorClause = afterRequestedAt == null
        ? ''
        : '''
          AND (
            r.requested_at > @afterRequestedAt
            OR (r.requested_at = @afterRequestedAt AND r.id > @afterRideId)
          )
        ''';

    final result = await database.execute(
      Sql.named('''
        SELECT
          r.id,
          r.client_request_id,
          r.pickup,
          r.pickup_latitude,
          r.pickup_longitude,
          r.destination,
          r.passengers,
          r.has_luggage,
          r.requested_at,
          r.status,
          r.assigned_driver_id,
          r.assigned_vehicle_id,
          r.dispatch_round,
          r.driver_bonus_minor,
          r.bonus_decision,
          r.currency,
          r.meter_fare_minor,
          r.commission_rate_bps,
          r.commission_amount_minor,
          r.completed_by_driver_id,
          r.completed_at
        FROM rides r
        WHERE r.status = 'waitingForVehicle'
          AND r.assigned_driver_id IS NULL
          AND r.assigned_vehicle_id IS NULL
          AND r.requested_at > @notBefore
          AND NOT EXISTS (
            SELECT 1
            FROM ride_offers ro
            WHERE ro.ride_id = r.id
              AND ro.status = 'pending'
          )
          $cursorClause
        ORDER BY r.requested_at ASC, r.id ASC
        LIMIT @limit
      '''),
      parameters: {
        'notBefore': notBefore.toUtc(),
        ...?(afterRequestedAt == null
            ? null
            : {
                'afterRequestedAt': afterRequestedAt.toUtc(),
                'afterRideId': afterRideId!,
              }),
        'limit': limit,
      },
    );

    return result
        .map((row) => _rideFromRow(row.toColumnMap()))
        .toList(growable: false);
  }

  RideRequest _rideFromRow(Map<String, dynamic> row) {
    return RideRequest(
      id: row['id'] as String,
      clientRequestId: row['client_request_id'] as String?,
      pickup: row['pickup'] as String,
      pickupLatitude: (row['pickup_latitude'] as num?)?.toDouble(),
      pickupLongitude: (row['pickup_longitude'] as num?)?.toDouble(),
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

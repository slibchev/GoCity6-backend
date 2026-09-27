import 'package:postgres/postgres.dart';

import 'ride_request.dart';
import 'ride_request_repository.dart';
import 'ride_request_status.dart';

class PostgresRideRequestRepository implements RideRequestRepository {
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
        'currency': request.currency,
        'meterFareMinor': request.meterFareMinor,
        'commissionRateBps': request.commissionRateBps,
        'commissionAmountMinor': request.commissionAmountMinor,
        'completedByDriverId': request.completedByDriverId,
        'completedAt': request.completedAt?.toUtc(),
      },
    );
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
      currency: (row['currency'] as String).trim(),
      meterFareMinor: row['meter_fare_minor'] as int?,
      commissionRateBps: row['commission_rate_bps'] as int?,
      commissionAmountMinor: row['commission_amount_minor'] as int?,
      completedByDriverId: row['completed_by_driver_id'] as String?,
      completedAt: (row['completed_at'] as DateTime?)?.toUtc(),
    );
  }
}

import 'package:postgres/postgres.dart';

import 'driver_assigned_vehicle_repository.dart';

class PostgresDriverAssignedVehicleRepository
    implements DriverAssignedVehicleRepository {
  final SessionExecutor database;

  PostgresDriverAssignedVehicleRepository({
    required this.database,
  });

  @override
  Future<DriverAssignedVehicle?> findByDriverId(String driverId) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            v.id,
            v.plate_number,
            v.is_active
          FROM drivers d
          JOIN vehicles v
            ON v.id = d.assigned_vehicle_id
          WHERE d.id = @driverId
            AND d.is_active = TRUE
          LIMIT 1
        '''),
        parameters: {
          'driverId': driverId,
        },
      );

      if (result.isEmpty) {
        return null;
      }

      final row = result.first.toColumnMap();

      return DriverAssignedVehicle(
        id: row['id'] as String,
        plateNumber: row['plate_number'] as String,
        isActive: row['is_active'] as bool,
      );
    });
  }
}
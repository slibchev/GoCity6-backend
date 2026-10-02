import 'package:postgres/postgres.dart';

import 'assigned_driver_info.dart';
import 'assigned_driver_info_repository.dart';

class PostgresAssignedDriverInfoRepository
    implements AssignedDriverInfoRepository {
  final SessionExecutor database;

  PostgresAssignedDriverInfoRepository({required this.database});

  @override
  Future<AssignedDriverInfo?> findByAssignment({
    required String driverId,
    required String vehicleId,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            d.id AS driver_id,
            d.first_name,
            d.last_name,
            d.phone,
            v.id AS vehicle_id,
            v.plate_number
          FROM drivers d
          CROSS JOIN vehicles v
          WHERE d.id = @driverId
            AND v.id = @vehicleId
          LIMIT 1
        '''),
        parameters: {'driverId': driverId, 'vehicleId': vehicleId},
      );

      if (result.isEmpty) {
        return null;
      }

      final row = result.first.toColumnMap();
      final firstName = row['first_name'] as String;
      final lastName = row['last_name'] as String;

      return AssignedDriverInfo(
        driverId: row['driver_id'] as String,
        vehicleId: row['vehicle_id'] as String,
        name: '$firstName $lastName'.trim(),
        phoneNumber: row['phone'] as String,
        licensePlate: row['plate_number'] as String,
      );
    });
  }
}

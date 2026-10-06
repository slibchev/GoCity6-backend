import 'package:postgres/postgres.dart';

import 'driver_live_location.dart';
import 'driver_live_location_repository.dart';

class PostgresDriverLiveLocationRepository
    implements DriverLiveLocationRepository {
  final SessionExecutor database;

  PostgresDriverLiveLocationRepository({
    required this.database,
  });

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            q.latitude,
            q.longitude,
            q.location_updated_at
          FROM driver_queue_states q
          JOIN driver_shifts s
            ON s.id = q.shift_id
          WHERE s.driver_id = @driverId
            AND s.ended_at IS NULL
            AND q.latitude IS NOT NULL
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

      return DriverLiveLocation(
        driverId: driverId,
        latitude: (row['latitude'] as num).toDouble(),
        longitude: (row['longitude'] as num).toDouble(),
        updatedAt: (row['location_updated_at'] as DateTime).toUtc(),
      );
    });
  }

  @override
  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  }) {
    final location = DriverLiveLocation(
      driverId: driverId,
      latitude: latitude,
      longitude: longitude,
      updatedAt: updatedAt.toUtc(),
    );

    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          UPDATE driver_queue_states q
          SET
            latitude = @latitude,
            longitude = @longitude,
            location_updated_at = @updatedAt
          FROM driver_shifts s
          WHERE q.shift_id = s.id
            AND s.driver_id = @driverId
            AND s.ended_at IS NULL
          RETURNING q.shift_id
        '''),
        parameters: {
          'driverId': location.driverId,
          'latitude': location.latitude,
          'longitude': location.longitude,
          'updatedAt': location.updatedAt,
        },
      );

      if (result.isEmpty) {
        throw StateError(
          'Active shift was not found for driver.',
        );
      }

      return location;
    });
  }
}
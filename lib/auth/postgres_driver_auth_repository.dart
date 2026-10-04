import 'package:postgres/postgres.dart';

import 'driver_authentication_service.dart';

class PostgresDriverAuthRepository implements DriverAuthRepository {
  PostgresDriverAuthRepository({
    required this.database,
  });

  final SessionExecutor database;

  @override
  Future<DriverAuthRecord?> findByUsername(String username) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            id,
            username,
            password_hash,
            first_name,
            last_name,
            phone,
            is_active
          FROM drivers
          WHERE LOWER(username) = LOWER(@username)
          LIMIT 1
        '''),
        parameters: {
          'username': username,
        },
      );

      if (result.isEmpty) {
        return null;
      }

      final row = result.first.toColumnMap();

      return DriverAuthRecord(
        id: row['id'] as String,
        username: row['username'] as String,
        passwordHash: row['password_hash'] as String,
        firstName: row['first_name'] as String,
        lastName: row['last_name'] as String,
        phone: row['phone'] as String,
        isActive: row['is_active'] as bool,
      );
    });
  }
}
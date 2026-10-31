import 'package:postgres/postgres.dart';

import 'passenger_authentication_service.dart';

class PostgresPassengerAuthRepository implements PassengerAuthRepository {
  const PostgresPassengerAuthRepository({required this.database});

  final SessionExecutor database;

  @override
  Future<PassengerAuthRecord?> findByUsername(String username) {
    return _find('LOWER(username) = LOWER(@value)', {'value': username});
  }

  @override
  Future<PassengerAuthRecord?> findById(String passengerId) {
    return _find('id = @value', {'value': passengerId});
  }

  Future<PassengerAuthRecord?> _find(
    String predicate,
    Map<String, Object?> parameters,
  ) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT id, username, password_hash, status
          FROM passengers
          WHERE $predicate
          LIMIT 1
        '''),
        parameters: parameters,
      );
      if (result.isEmpty) {
        return null;
      }

      final row = result.first.toColumnMap();
      return PassengerAuthRecord(
        id: row['id'] as String,
        username: row['username'] as String,
        passwordHash: row['password_hash'] as String,
        status: row['status'] as String,
      );
    });
  }
}

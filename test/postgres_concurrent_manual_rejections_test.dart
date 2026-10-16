import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/driver_dispatch_policy_service.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_dispatch_state_repository.dart';

void main() {
  test('two concurrent manual rejects are both counted', () async {
    final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

    if (password == null || password.isEmpty) {
      fail('CITY6_TEST_DB_PASSWORD is required.');
    }

    Future<Connection> openConnection() {
      return Connection.open(
        Endpoint(
          host: 'localhost',
          port: 5432,
          database: 'city6_test',
          username: 'city6_app',
          password: password,
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
    }

    final db1 = await openConnection();
    final db2 = await openConnection();

    final driverId = const Uuid().v4();
    final now = DateTime.now().toUtc();

    try {
      final dbName = await db1.execute('SELECT current_database()');
      expect(dbName.first[0], 'city6_test');

      await db1.execute(
        Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash,
            first_name, last_name, phone, created_at
          )
          VALUES (
            @id, @username, 'test',
            'Test', 'Driver', '000', @now
          )
        '''),
        parameters: {
          'id': driverId,
          'username': 'concurrent-$driverId',
          'now': now,
        },
      );

      final service1 = DriverDispatchPolicyService(
        repository: PostgresDriverDispatchStateRepository(database: db1),
      );

      final service2 = DriverDispatchPolicyService(
        repository: PostgresDriverDispatchStateRepository(database: db2),
      );

      // Two independent connections update the same driver.
      await Future.wait([
        service1.recordRejectedOffer(driverId: driverId, now: now),
        service2.recordRejectedOffer(driverId: driverId, now: now),
      ]);

      final rows = await db1.execute(
        Sql.named('''
          SELECT
            consecutive_rejects,
            penalty_level,
            dispatch_blocked_until
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
        '''),
        parameters: {'driverId': driverId},
      );

      expect(rows, hasLength(1));

      final state = rows.single.toColumnMap();

      expect(state['consecutive_rejects'], 2);
      expect(state['penalty_level'], 0);
      expect(state['dispatch_blocked_until'], isNull);
    } finally {
      try {
        await db1.execute(
          Sql.named('''
            DELETE FROM driver_dispatch_states
            WHERE driver_id = @driverId
          '''),
          parameters: {'driverId': driverId},
        );

        await db1.execute(
          Sql.named('''
            DELETE FROM drivers
            WHERE id = @driverId
          '''),
          parameters: {'driverId': driverId},
        );
      } finally {
        await db2.close();
        await db1.close();
      }
    }
  });
}

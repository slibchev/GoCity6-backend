import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';

void main() {
  test('PostgreSQL returns free waiting rides in order', () async {
    final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

    if (password == null || password.isEmpty) {
      fail('CITY6_TEST_DB_PASSWORD is required.');
    }

    final db = await Connection.open(
      Endpoint(
        host: 'localhost',
        database: 'city6_test',
        username: 'city6_app',
        password: password,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    final uuid = const Uuid();
    final olderId = uuid.v4();
    final newerId = uuid.v4();
    final pendingId = uuid.v4();
    final ids = [olderId, newerId, pendingId];

    try {
      final dbName = await db.execute('SELECT current_database()');
      expect(dbName.first[0], 'city6_test');

      final time = DateTime.utc(2026, 10, 1, 10);

      for (final id in ids) {
        await db.execute(
          Sql.named('''
            INSERT INTO rides (
              id, pickup, destination,
              passengers, requested_at, status
            )
            VALUES (
              @id, 'Test pickup', 'Test destination',
              2, @requestedAt, @status
            )
          '''),
          parameters: {
            'id': id,
            'requestedAt': id == olderId
                ? time
                : time.add(const Duration(hours: 1)),
            'status': id == pendingId ? 'pending' : 'waitingForVehicle',
          },
        );
      }

      final repository = PostgresRideRequestRepository(database: db);
      final waiting = await repository.findWaitingForVehicle();

      final testRideIds = waiting
          .map((ride) => ride.id)
          .where(ids.contains)
          .toList();

      expect(testRideIds, [olderId, newerId]);
    } finally {
      try {
        await db.execute(
          Sql.named('''
            DELETE FROM rides
            WHERE id IN (@olderId, @newerId, @pendingId)
          '''),
          parameters: {
            'olderId': olderId,
            'newerId': newerId,
            'pendingId': pendingId,
          },
        );
      } finally {
        await db.close();
      }
    }
  });
}

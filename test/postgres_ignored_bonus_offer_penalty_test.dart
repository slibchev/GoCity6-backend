import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/postgres_ignored_offer_penalty_service.dart';

void main() {
  test('ignored bonus offer blocks driver for 30 minutes', () async {
    final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

    if (password == null || password.isEmpty) {
      fail('CITY6_TEST_DB_PASSWORD is required.');
    }

    final db = await Connection.open(
      Endpoint(
        host: 'localhost',
        port: 5432,
        database: 'city6_test',
        username: 'city6_app',
        password: password,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    final uuid = const Uuid();
    final driverId = uuid.v4();
    final vehicleId = uuid.v4();
    final rideId = uuid.v4();
    final offerId = uuid.v4();

    final now = DateTime.now().toUtc();
    final recoveryTime = now.add(const Duration(hours: 1));
    final offeredAt = now.subtract(const Duration(seconds: 20));
    final expiresAt = offeredAt.add(const Duration(seconds: 15));

    try {
      final databaseName = await db.execute('SELECT current_database()');
      expect(databaseName.first[0], 'city6_test');

      await db.execute(
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
        parameters: {'id': driverId, 'username': 'bonus-$driverId', 'now': now},
      );

      await db.execute(
        Sql.named('''
          INSERT INTO vehicles (id, plate_number, created_at)
          VALUES (@id, @plate, @now)
        '''),
        parameters: {'id': vehicleId, 'plate': 'TEST-$vehicleId', 'now': now},
      );

      await db.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination,
            passengers, requested_at, status
          )
          VALUES (
            @id, 'Bonus pickup', 'Bonus destination',
            2, @requestedAt, 'pending'
          )
        '''),
        parameters: {
          'id': rideId,
          'requestedAt': offeredAt.subtract(
            const Duration(minutes: 19, seconds: 59),
          ),
        },
      );

      await db.execute(
        Sql.named('''
          INSERT INTO ride_offers (
            id, ride_id, driver_id, vehicle_id,
            eta_seconds, distance_meters,
            dispatch_round, bonus_minor,
            offered_at, expires_at,
            status, resolved_at, displayed_at
          )
          VALUES (
            @offerId, @rideId, @driverId, @vehicleId,
            120, 1000,
            2, 500,
            @offeredAt, @expiresAt,
            'expired', @now, @displayedAt
          )
        '''),
        parameters: {
          'offerId': offerId,
          'rideId': rideId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'offeredAt': offeredAt,
          'expiresAt': expiresAt,
          'displayedAt': offeredAt.add(const Duration(seconds: 2)),
          'now': now,
        },
      );

      final db2 = await Connection.open(
        Endpoint(
          host: 'localhost',
          port: 5432,
          database: 'city6_test',
          username: 'city6_app',
          password: password,
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );

      final service = PostgresIgnoredOfferPenaltyService(database: db);
      final service2 = PostgresIgnoredOfferPenaltyService(database: db2);

      final results = await Future.wait([
        service.recordIgnoredOffer(offerId: offerId, now: recoveryTime),
        service2.recordIgnoredOffer(offerId: offerId, now: recoveryTime),
      ]);

      await db2.close();

      expect(results.where((result) => result).length, 1);
      expect(results.where((result) => !result).length, 1);

      final rows = await db.execute(
        Sql.named('''
          SELECT consecutive_rejects, penalty_level, dispatch_blocked_until,
                 requires_completed_ride_after_penalty
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
        '''),
        parameters: {'driverId': driverId},
      );

      final state = rows.single.toColumnMap();

      expect(state['consecutive_rejects'], 0);
      expect(state['penalty_level'], 0);
      expect(state['requires_completed_ride_after_penalty'], isFalse);
      expect(
        (state['dispatch_blocked_until'] as DateTime).toUtc(),
        expiresAt.add(const Duration(minutes: 30)),
      );
    } finally {
      try {
        await db.execute(
          Sql.named(
            'DELETE FROM ignored_offer_penalty_tracking WHERE offer_id = @id',
          ),
          parameters: {'id': offerId},
        );
        await db.execute(
          Sql.named('DELETE FROM driver_dispatch_states WHERE driver_id = @id'),
          parameters: {'id': driverId},
        );
        await db.execute(
          Sql.named('DELETE FROM ride_offers WHERE id = @id'),
          parameters: {'id': offerId},
        );
        await db.execute(
          Sql.named('DELETE FROM rides WHERE id = @id'),
          parameters: {'id': rideId},
        );
        await db.execute(
          Sql.named('DELETE FROM vehicles WHERE id = @id'),
          parameters: {'id': vehicleId},
        );
        await db.execute(
          Sql.named('DELETE FROM drivers WHERE id = @id'),
          parameters: {'id': driverId},
        );
      } finally {
        await db.close();
      }
    }
  });
}

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/postgres_ignored_offer_penalty_service.dart';

void main() {
  test('three ignored regular offers cause one 30-minute block', () async {
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
    final rideIds = List.generate(3, (_) => uuid.v4());
    final offerIds = List.generate(3, (_) => uuid.v4());

    final now = DateTime.now().toUtc();

    try {
      final dbName = await db.execute('SELECT current_database()');
      expect(dbName.first[0], 'city6_test');

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
        parameters: {
          'id': driverId,
          'username': 'regular-$driverId',
          'now': now,
        },
      );

      await db.execute(
        Sql.named('''
          INSERT INTO vehicles (id, plate_number, created_at)
          VALUES (@id, @plate, @now)
        '''),
        parameters: {'id': vehicleId, 'plate': 'TEST-$vehicleId', 'now': now},
      );

      for (var i = 0; i < 3; i++) {
        await db.execute(
          Sql.named('''
            INSERT INTO rides (
              id, pickup, destination,
              passengers, requested_at, status
            )
            VALUES (
              @id, 'Test pickup', 'Test destination',
              2, @requestedAt, 'pending'
            )
          '''),
          parameters: {
            'id': rideIds[i],
            'requestedAt': now
                .subtract(Duration(minutes: 3 - i))
                .subtract(const Duration(minutes: 19)),
          },
        );

        final offeredAt = now.subtract(Duration(minutes: 3 - i));
        final expiresAt = offeredAt.add(const Duration(seconds: 15));

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
              1, 0,
              @offeredAt, @expiresAt,
              'expired', @now, @displayedAt
            )
          '''),
          parameters: {
            'offerId': offerIds[i],
            'rideId': rideIds[i],
            'driverId': driverId,
            'vehicleId': vehicleId,
            'offeredAt': offeredAt,
            'expiresAt': expiresAt,
            'displayedAt': offeredAt.add(const Duration(seconds: 2)),
            'now': now,
          },
        );
      }

      final service = PostgresIgnoredOfferPenaltyService(database: db);

      final recovered = await service.recoverUnprocessedIgnoredOffers(
        now: now.add(const Duration(hours: 1)),
      );

      expect(recovered, 3);

      final rows = await db.execute(
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

      final state = rows.single.toColumnMap();

      expect(state['consecutive_rejects'], 0);
      expect(state['penalty_level'], 1);

      final thirdExpiresAt = now
          .subtract(const Duration(minutes: 1))
          .add(const Duration(seconds: 15));

      expect(
        (state['dispatch_blocked_until'] as DateTime).toUtc(),
        thirdExpiresAt.add(const Duration(minutes: 30)),
      );

      final secondRecovery = await service.recoverUnprocessedIgnoredOffers(
        now: now.add(const Duration(hours: 2)),
      );

      expect(secondRecovery, 0);
    } finally {
      try {
        await db.execute(
          Sql.named('''
            DELETE FROM ignored_offer_penalty_tracking
            WHERE offer_id = ANY(@ids)
          '''),
          parameters: {'ids': offerIds},
        );

        await db.execute(
          Sql.named('DELETE FROM driver_dispatch_states WHERE driver_id = @id'),
          parameters: {'id': driverId},
        );

        for (var i = 0; i < 3; i++) {
          await db.execute(
            Sql.named('DELETE FROM ride_offers WHERE id = @id'),
            parameters: {'id': offerIds[i]},
          );

          await db.execute(
            Sql.named('DELETE FROM rides WHERE id = @id'),
            parameters: {'id': rideIds[i]},
          );
        }

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

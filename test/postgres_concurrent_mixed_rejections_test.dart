import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/driver_dispatch_policy_service.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_ignored_offer_penalty_service.dart';

void main() {
  test('concurrent manual and ignored offers count exactly once', () async {
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

    final uuid = const Uuid();
    final driverId = uuid.v4();
    final vehicleId = uuid.v4();
    final rideId = uuid.v4();
    final offerId = uuid.v4();

    final now = DateTime.now().toUtc();
    final offeredAt = now.subtract(const Duration(seconds: 15));
    final displayedAt = offeredAt.add(const Duration(seconds: 2));
    final expectedBlockedUntil = now.add(const Duration(minutes: 30));

    try {
      final databaseName = await db1.execute('SELECT current_database()');
      expect(databaseName.first[0], 'city6_test');

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
        parameters: {'id': driverId, 'username': 'mixed-$driverId', 'now': now},
      );

      await db1.execute(
        Sql.named('''
          INSERT INTO vehicles (id, plate_number, created_at)
          VALUES (@id, @plate, @now)
        '''),
        parameters: {'id': vehicleId, 'plate': 'TEST-$vehicleId', 'now': now},
      );

      await db1.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination,
            passengers, requested_at, status
          )
          VALUES (
            @id, 'Test pickup', 'Test destination',
            2, @now, 'pending'
          )
        '''),
        parameters: {'id': rideId, 'now': now},
      );

      await db1.execute(
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
          'offerId': offerId,
          'rideId': rideId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'offeredAt': offeredAt,
          'expiresAt': now,
          'displayedAt': displayedAt,
          'now': now,
        },
      );

      // One previously recorded rejection.
      await db1.execute(
        Sql.named('''
          INSERT INTO driver_dispatch_states (
            driver_id,
            consecutive_rejects,
            penalty_level
          )
          VALUES (@driverId, 1, 0)
        '''),
        parameters: {'driverId': driverId},
      );

      final manualService = DriverDispatchPolicyService(
        repository: PostgresDriverDispatchStateRepository(database: db1),
      );

      final ignoredService = PostgresIgnoredOfferPenaltyService(database: db2);

      // Run both updates over independent connections.
      final results = await Future.wait<Object>([
        manualService.recordRejectedOffer(driverId: driverId, now: now),
        ignoredService.recordIgnoredOffer(offerId: offerId, now: now),
      ]);

      expect(results[1], isTrue);

      final states = await db1.execute(
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

      expect(states, hasLength(1));

      final state = states.single.toColumnMap();

      expect(state['consecutive_rejects'], 0);
      expect(state['penalty_level'], 1);
      expect(
        (state['dispatch_blocked_until'] as DateTime).toUtc(),
        expectedBlockedUntil,
      );

      final tracking = await db1.execute(
        Sql.named('''
          SELECT COUNT(*)
          FROM ignored_offer_penalty_tracking
          WHERE offer_id = @offerId
        '''),
        parameters: {'offerId': offerId},
      );

      expect(tracking.single[0], 1);

      // Retrying the ignored offer must not count again.
      final duplicate = await ignoredService.recordIgnoredOffer(
        offerId: offerId,
        now: now,
      );

      expect(duplicate, isFalse);

      final finalStates = await db1.execute(
        Sql.named('''
          SELECT consecutive_rejects, penalty_level
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
        '''),
        parameters: {'driverId': driverId},
      );

      expect(finalStates.single[0], 0);
      expect(finalStates.single[1], 1);
    } finally {
      try {
        await db1.execute(
          Sql.named('''
            DELETE FROM ignored_offer_penalty_tracking
            WHERE offer_id = @offerId
          '''),
          parameters: {'offerId': offerId},
        );

        await db1.execute(
          Sql.named('''
            DELETE FROM driver_dispatch_states
            WHERE driver_id = @driverId
          '''),
          parameters: {'driverId': driverId},
        );

        await db1.execute(
          Sql.named('''
            DELETE FROM ride_offers
            WHERE id = @offerId
          '''),
          parameters: {'offerId': offerId},
        );

        await db1.execute(
          Sql.named('''
            DELETE FROM rides
            WHERE id = @rideId
          '''),
          parameters: {'rideId': rideId},
        );

        await db1.execute(
          Sql.named('''
            DELETE FROM vehicles
            WHERE id = @vehicleId
          '''),
          parameters: {'vehicleId': vehicleId},
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

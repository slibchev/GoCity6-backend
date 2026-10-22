import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/postgres_ignored_offer_penalty_service.dart';

void main() {
  test('ignored offer penalty is applied exactly once', () async {
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
    final undisplayedRideId = uuid.v4();
    final offerId = uuid.v4();
    final undisplayedOfferId = uuid.v4();

    final now = DateTime.now().toUtc();
    final offeredAt = now.subtract(const Duration(seconds: 20));
    final expiresAt = offeredAt.add(const Duration(seconds: 15));
    final displayedAt = offeredAt.add(const Duration(seconds: 2));

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
        parameters: {
          'id': driverId,
          'username': 'penalty-$driverId',
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
          'expiresAt': expiresAt,
          'displayedAt': displayedAt,
          'now': now,
        },
      );
      // An expired offer that was never displayed must not be penalized.
      await db.execute(
        Sql.named('''
    INSERT INTO rides (
      id, pickup, destination,
      passengers, requested_at, status
    )
    VALUES (
      @id, 'Test pickup 2', 'Test destination 2',
      2, @now, 'pending'
    )
  '''),
        parameters: {'id': undisplayedRideId, 'now': now},
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
      @id, @rideId, @driverId, @vehicleId,
      120, 1000,
      1, 0,
      @offeredAt, @expiresAt,
      'expired', @now, NULL
    )
  '''),
        parameters: {
          'id': undisplayedOfferId,
          'rideId': undisplayedRideId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'offeredAt': offeredAt,
          'expiresAt': expiresAt,
          'now': now,
        },
      );
      // Simulate two previous manual rejections.
      await db.execute(
        Sql.named('''
    INSERT INTO driver_dispatch_states (
      driver_id,
      consecutive_rejects,
      penalty_level
    )
    VALUES (@driverId, 2, 0)
  '''),
        parameters: {'driverId': driverId},
      );

      final service = PostgresIgnoredOfferPenaltyService(database: db);
      final undisplayedResult = await service.recordIgnoredOffer(
        offerId: undisplayedOfferId,
        now: now,
      );

      expect(undisplayedResult, isFalse);

      final firstRecovery = await service.recoverUnprocessedIgnoredOffers(
        now: now,
      );

      final secondRecovery = await service.recoverUnprocessedIgnoredOffers(
        now: now,
      );

      expect(firstRecovery, 1);
      expect(secondRecovery, 0);
      // A recovered regular offer counts as one rejection.
      final recoveredAt = now.add(const Duration(hours: 1));

      final repeatRecovery = await service.recoverUnprocessedIgnoredOffers(
        now: recoveredAt,
      );

      expect(repeatRecovery, 0);

      final states = await db.execute(
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

      expect(states.single[0], 0);
      expect(states.single[1], 1);
      expect(
        (states.single[2] as DateTime).toUtc(),
        expiresAt.add(const Duration(minutes: 30)),
      );

      final tracking = await db.execute(
        Sql.named('''
          SELECT COUNT(*)
          FROM ignored_offer_penalty_tracking
          WHERE offer_id = @offerId
        '''),
        parameters: {'offerId': offerId},
      );

      expect(tracking.single[0], 1);
    } finally {
      try {
        await db.execute(
          Sql.named('''
            DELETE FROM ignored_offer_penalty_tracking
            WHERE offer_id IN (@offerId, @undisplayedOfferId)
          '''),
          parameters: {
            'offerId': offerId,
            'undisplayedOfferId': undisplayedOfferId,
          },
        );
        await db.execute(
          Sql.named('''
            DELETE FROM ride_offers
            WHERE id IN (@offerId, @undisplayedOfferId)
          '''),
          parameters: {
            'offerId': offerId,
            'undisplayedOfferId': undisplayedOfferId,
          },
        );
        await db.execute(
          Sql.named('DELETE FROM driver_dispatch_states WHERE driver_id = @id'),
          parameters: {'id': driverId},
        );
        await db.execute(
          Sql.named('''
            DELETE FROM rides
            WHERE id IN (@rideId, @undisplayedRideId)
          '''),
          parameters: {
            'rideId': rideId,
            'undisplayedRideId': undisplayedRideId,
          },
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

  test(
    'ignored offers at 20 minutes are tracked without changing state',
    () async {
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
      final rideIds = List.generate(2, (_) => uuid.v4());
      final offerIds = List.generate(2, (_) => uuid.v4());
      final now = DateTime.now().toUtc();
      final offeredAt = now.subtract(const Duration(seconds: 20));
      final requestedAt = offeredAt.subtract(const Duration(minutes: 20));
      final expiresAt = offeredAt.add(const Duration(seconds: 15));
      final blockedUntil = now.add(const Duration(minutes: 12));
      final resetEligibleAt = now.add(const Duration(hours: 3));

      try {
        final databaseName = await db.execute('SELECT current_database()');
        expect(databaseName.single[0], 'city6_test');

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
            'username': 'ignored-boundary-$driverId',
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

        for (var i = 0; i < 2; i++) {
          await db.execute(
            Sql.named('''
            INSERT INTO rides (
              id, pickup, destination,
              passengers, requested_at, status
            )
            VALUES (
              @id, 'Boundary pickup', 'Boundary destination',
              2, @requestedAt, 'pending'
            )
          '''),
            parameters: {'id': rideIds[i], 'requestedAt': requestedAt},
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
              @dispatchRound, @bonusMinor,
              @offeredAt, @expiresAt,
              'expired', @now, @displayedAt
            )
          '''),
            parameters: {
              'offerId': offerIds[i],
              'rideId': rideIds[i],
              'driverId': driverId,
              'vehicleId': vehicleId,
              'dispatchRound': i == 0 ? 1 : 2,
              'bonusMinor': i == 0 ? 0 : 500,
              'offeredAt': offeredAt,
              'expiresAt': expiresAt,
              'displayedAt': offeredAt.add(const Duration(seconds: 2)),
              'now': now,
            },
          );
        }

        await db.execute(
          Sql.named('''
          INSERT INTO driver_dispatch_states (
            driver_id,
            consecutive_rejects,
            penalty_level,
            dispatch_blocked_until,
            penalty_reset_eligible_at
          )
          VALUES (@driverId, 2, 3, @blockedUntil, @resetEligibleAt)
        '''),
          parameters: {
            'driverId': driverId,
            'blockedUntil': blockedUntil,
            'resetEligibleAt': resetEligibleAt,
          },
        );

        final service = PostgresIgnoredOfferPenaltyService(database: db);
        for (final offerId in offerIds) {
          expect(
            await service.recordIgnoredOffer(offerId: offerId, now: now),
            isFalse,
          );
          expect(
            await service.recordIgnoredOffer(offerId: offerId, now: now),
            isFalse,
          );
        }

        final states = await db.execute(
          Sql.named('''
          SELECT
            consecutive_rejects,
            penalty_level,
            dispatch_blocked_until,
            penalty_reset_eligible_at
          FROM driver_dispatch_states
          WHERE driver_id = @driverId
        '''),
          parameters: {'driverId': driverId},
        );
        final state = states.single.toColumnMap();
        expect(state['consecutive_rejects'], 2);
        expect(state['penalty_level'], 3);
        expect(
          (state['dispatch_blocked_until'] as DateTime).toUtc(),
          blockedUntil,
        );
        expect(
          (state['penalty_reset_eligible_at'] as DateTime).toUtc(),
          resetEligibleAt,
        );

        final tracking = await db.execute(
          Sql.named('''
          SELECT COUNT(*)
          FROM ignored_offer_penalty_tracking
          WHERE offer_id = ANY(@offerIds)
        '''),
          parameters: {'offerIds': offerIds},
        );
        expect(tracking.single[0], 2);
      } finally {
        try {
          await db.execute(
            Sql.named('''
            DELETE FROM ignored_offer_penalty_tracking
            WHERE offer_id = ANY(@offerIds)
          '''),
            parameters: {'offerIds': offerIds},
          );
          await db.execute(
            Sql.named('DELETE FROM ride_offers WHERE id = ANY(@offerIds)'),
            parameters: {'offerIds': offerIds},
          );
          await db.execute(
            Sql.named(
              'DELETE FROM driver_dispatch_states WHERE driver_id = @id',
            ),
            parameters: {'id': driverId},
          );
          await db.execute(
            Sql.named('DELETE FROM rides WHERE id = ANY(@rideIds)'),
            parameters: {'rideIds': rideIds},
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
    },
  );
}

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_waiting_ride_acceptance_repository.dart';

void main() {
  test('two drivers compete for the same waiting ride', () async {
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
    final driverIds = [uuid.v4(), uuid.v4()];
    final vehicleIds = [uuid.v4(), uuid.v4()];
    final shiftIds = [uuid.v4(), uuid.v4()];
    final rideId = uuid.v4();
    final now = DateTime.now().toUtc();

    try {
      final name1 = await db1.execute('SELECT current_database()');
      final name2 = await db2.execute('SELECT current_database()');

      expect(name1.single[0], 'city6_test');
      expect(name2.single[0], 'city6_test');

      for (var i = 0; i < 2; i++) {
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
            'id': driverIds[i],
            'username': 'race-${driverIds[i]}',
            'now': now,
          },
        );

        await db1.execute(
          Sql.named('''
            INSERT INTO vehicles (
              id, plate_number, created_at
            )
            VALUES (@id, @plate, @now)
          '''),
          parameters: {
            'id': vehicleIds[i],
            'plate': 'TEST-${vehicleIds[i]}',
            'now': now,
          },
        );

        await db1.execute(
          Sql.named('''
            INSERT INTO driver_shifts (
              id, driver_id, vehicle_id,
              started_at, protected_breaks_used
            )
            VALUES (
              @shiftId, @driverId, @vehicleId, @now, 0
            )
          '''),
          parameters: {
            'shiftId': shiftIds[i],
            'driverId': driverIds[i],
            'vehicleId': vehicleIds[i],
            'now': now,
          },
        );

        await db1.execute(
          Sql.named('''
            INSERT INTO driver_queue_states (
              shift_id, availability,
              queue_priority_since,
              break_started_at, has_pending_offer
            )
            VALUES (
              @shiftId, 'available', @now, NULL, FALSE
            )
          '''),
          parameters: {'shiftId': shiftIds[i], 'now': now},
        );
      }

      await db1.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination,
            passengers, requested_at, status
          )
          VALUES (
            @rideId, 'Race test pickup', 'Race test destination',
            2, @now, 'waitingForVehicle'
          )
        '''),
        parameters: {'rideId': rideId, 'now': now},
      );

      Future<bool> attemptClaim(Connection connection, String driverId) async {
        final repository = PostgresAtomicWaitingRideAcceptanceRepository(
          database: connection,
        );

        try {
          final acceptedRide = await repository.acceptWaitingRide(
            rideId: rideId,
            driverId: driverId,
          );

          expect(acceptedRide.status.name, 'accepted');
          expect(acceptedRide.assignedDriverId, driverId);

          return true;
        } on AtomicWaitingRideAcceptanceConflictException catch (error) {
          expect(
            error.conflict,
            AtomicWaitingRideAcceptanceConflict.rideNotWaitingForVehicle,
          );

          return false;
        }
      }

      final results = await Future.wait([
        attemptClaim(db1, driverIds[0]),
        attemptClaim(db2, driverIds[1]),
      ]);

      expect(results.where((accepted) => accepted).length, 1);
      expect(results.where((accepted) => !accepted).length, 1);

      final rideRows = await db1.execute(
        Sql.named('''
          SELECT
            status,
            assigned_driver_id,
            assigned_vehicle_id
          FROM rides
          WHERE id = @rideId
        '''),
        parameters: {'rideId': rideId},
      );

      expect(rideRows, hasLength(1));

      final savedRide = rideRows.single.toColumnMap();
      final winnerIndex = results.indexOf(true);

      expect(savedRide['status'], 'accepted');
      expect(savedRide['assigned_driver_id'], driverIds[winnerIndex]);
      expect(savedRide['assigned_vehicle_id'], vehicleIds[winnerIndex]);

      for (var i = 0; i < 2; i++) {
        final queueRows = await db1.execute(
          Sql.named('''
            SELECT availability
            FROM driver_queue_states
            WHERE shift_id = @shiftId
          '''),
          parameters: {'shiftId': shiftIds[i]},
        );

        expect(queueRows, hasLength(1));

        expect(queueRows.single[0], results[i] ? 'busy' : 'available');
      }
    } finally {
      try {
        await db1.execute(
          Sql.named('DELETE FROM rides WHERE id = @rideId'),
          parameters: {'rideId': rideId},
        );

        for (final id in shiftIds) {
          await db1.execute(
            Sql.named('DELETE FROM driver_queue_states WHERE shift_id = @id'),
            parameters: {'id': id},
          );
        }

        for (final id in shiftIds) {
          await db1.execute(
            Sql.named('DELETE FROM driver_shifts WHERE id = @id'),
            parameters: {'id': id},
          );
        }

        for (final id in vehicleIds) {
          await db1.execute(
            Sql.named('DELETE FROM vehicles WHERE id = @id'),
            parameters: {'id': id},
          );
        }

        for (final id in driverIds) {
          await db1.execute(
            Sql.named('DELETE FROM drivers WHERE id = @id'),
            parameters: {'id': id},
          );
        }
      } finally {
        await db2.close();
        await db1.close();
      }
    }
  });
}

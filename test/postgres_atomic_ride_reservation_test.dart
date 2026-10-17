import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/postgres_atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_lifecycle_service.dart';

void main() {
  test('busy driver reserves next waiting ride in PostgreSQL', () async {
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
    final shiftId = uuid.v4();
    final currentRideId = uuid.v4();
    final nextRideId = uuid.v4();
    final reservationId = uuid.v4();
    final thirdRideId = uuid.v4();
    final now = DateTime.now().toUtc();

    try {
      final result = await db.execute('SELECT current_database()');

      expect(result.single[0], 'city6_test');

      await db.execute(
        Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash,
            first_name, last_name, phone, created_at
          )
          VALUES (
            @id, @username, 'test',
            'Reservation', 'Test Driver', '000', @now
          )
        '''),
        parameters: {
          'id': driverId,
          'username': 'reservation-$driverId',
          'now': now,
        },
      );

      await db.execute(
        Sql.named('''
          INSERT INTO vehicles (
            id, plate_number, created_at
          )
          VALUES (@id, @plate, @now)
        '''),
        parameters: {'id': vehicleId, 'plate': 'TEST-$vehicleId', 'now': now},
      );

      await db.execute(
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
          'shiftId': shiftId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'now': now,
        },
      );

      await db.execute(
        Sql.named('''
          INSERT INTO driver_queue_states (
            shift_id, availability,
            queue_priority_since,
            break_started_at, has_pending_offer
          )
          VALUES (
            @shiftId, 'busy', @now, NULL, FALSE
          )
        '''),
        parameters: {'shiftId': shiftId, 'now': now},
      );

      // Текуща поръчка, която шофьорът изпълнява.
      await db.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination,
            passengers, requested_at, status,
            assigned_driver_id, assigned_vehicle_id
          )
          VALUES (
            @id, 'Current pickup', 'Current destination',
            2, @now, 'inProgress',
            @driverId, @vehicleId
          )
        '''),
        parameters: {
          'id': currentRideId,
          'now': now,
          'driverId': driverId,
          'vehicleId': vehicleId,
        },
      );

      // Следваща поръчка, която очаква резервиране.
      await db.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination,
            passengers, requested_at, status
          )
          VALUES (
            @id, 'Next pickup', 'Next destination',
            2, @now, 'waitingForVehicle'
          )
        '''),
        parameters: {'id': nextRideId, 'now': now},
      );

      final reservationRepository = PostgresAtomicRideReservationRepository(
        database: db,
      );

      final reservation = await reservationRepository.reserveWaitingRide(
        reservationId: reservationId,
        rideId: nextRideId,
        driverId: driverId,
        combinedEtaSeconds: 300,
        now: now,
      );

      expect(reservation.id, reservationId);
      expect(reservation.rideId, nextRideId);
      expect(reservation.driverId, driverId);
      expect(reservation.vehicleId, vehicleId);
      expect(reservation.shiftId, shiftId);
      expect(reservation.isActive, isTrue);

      final rideRows = await db.execute(
        Sql.named('''
          SELECT status, assigned_driver_id, assigned_vehicle_id
          FROM rides
          WHERE id = @id
        '''),
        parameters: {'id': nextRideId},
      );

      expect(rideRows, hasLength(1));

      final savedRide = rideRows.single.toColumnMap();

      expect(savedRide['status'], 'reserved');
      expect(savedRide['assigned_driver_id'], isNull);
      expect(savedRide['assigned_vehicle_id'], isNull);

      // Създаваме трета чакаща поръчка.
      await db.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination,
            passengers, requested_at, status
          )
          VALUES (
            @id, 'Third pickup', 'Third destination',
            2, @now, 'waitingForVehicle'
          )
        '''),
        parameters: {'id': thirdRideId, 'now': now},
      );

      // Шофьорът вече има активна резервация.
      // Опитът за втора трябва да бъде отказан.
      await expectLater(
        reservationRepository.reserveWaitingRide(
          reservationId: uuid.v4(),
          rideId: thirdRideId,
          driverId: driverId,
          combinedEtaSeconds: 300,
          now: now,
        ),
        throwsA(
          isA<AtomicRideReservationConflictException>().having(
            (error) => error.conflict,
            'conflict',
            AtomicRideReservationConflict.driverAlreadyHasReservedRide,
          ),
        ),
      );

      // Третата поръчка трябва да остане свободна.
      final thirdRideRows = await db.execute(
        Sql.named('''
          SELECT status, assigned_driver_id, assigned_vehicle_id
          FROM rides
          WHERE id = @rideId
        '''),
        parameters: {'rideId': thirdRideId},
      );

      expect(thirdRideRows, hasLength(1));

      final thirdRide = thirdRideRows.single.toColumnMap();

      expect(thirdRide['status'], 'waitingForVehicle');
      expect(thirdRide['assigned_driver_id'], isNull);
      expect(thirdRide['assigned_vehicle_id'], isNull);

      // Шофьорът трябва да има точно една активна резервация.
      final reservationRows = await db.execute(
        Sql.named('''
          SELECT ride_id, vehicle_id
          FROM ride_reservations
          WHERE driver_id = @driverId
            AND ended_at IS NULL
        '''),
        parameters: {'driverId': driverId},
      );

      expect(reservationRows, hasLength(1));
      expect(reservationRows.single[0], nextRideId);
      expect(reservationRows.single[1], vehicleId);

      // Приключваме текущата поръчка.
      final lifecycleService = RideLifecycleService(
        repository: PostgresRideRequestRepository(database: db),
      );

      final completedRide = await lifecycleService.completeRide(
        rideId: currentRideId,
        driverId: driverId,
        meterFareMinor: 1200,
      );

      expect(completedRide.status.name, 'completed');

      // Резервираната поръчка трябва автоматично
      // да стане текуща за същия шофьор.
      final promotedRows = await db.execute(
        Sql.named('''
          SELECT status, assigned_driver_id, assigned_vehicle_id
          FROM rides
          WHERE id = @rideId
        '''),
        parameters: {'rideId': nextRideId},
      );

      expect(promotedRows, hasLength(1));

      final promotedRide = promotedRows.single.toColumnMap();

      expect(promotedRide['status'], 'accepted');
      expect(promotedRide['assigned_driver_id'], driverId);
      expect(promotedRide['assigned_vehicle_id'], vehicleId);

      // Активната резервация трябва да е приключена.
      final endedReservation = await db.execute(
        Sql.named('''
          SELECT ended_at
          FROM ride_reservations
          WHERE id = @reservationId
        '''),
        parameters: {'reservationId': reservationId},
      );

      expect(endedReservation, hasLength(1));
      expect(endedReservation.single[0], isNotNull);
    } finally {
      try {
        await db.execute(
          Sql.named('''
            DELETE FROM ride_reservations
            WHERE ride_id IN (@nextRideId, @thirdRideId)
          '''),
          parameters: {'nextRideId': nextRideId, 'thirdRideId': thirdRideId},
        );

        for (final rideId in [thirdRideId, nextRideId, currentRideId]) {
          await db.execute(
            Sql.named('DELETE FROM rides WHERE id = @id'),
            parameters: {'id': rideId},
          );
        }

        await db.execute(
          Sql.named('DELETE FROM driver_queue_states WHERE shift_id = @id'),
          parameters: {'id': shiftId},
        );

        await db.execute(
          Sql.named('DELETE FROM driver_shifts WHERE id = @id'),
          parameters: {'id': shiftId},
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

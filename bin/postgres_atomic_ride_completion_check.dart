import 'dart:io';

import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:postgres/postgres.dart';

Future<void> main() async {
  final password = Platform.environment['CITY6_DB_PASSWORD'];

  if (password == null || password.isEmpty) {
    stderr.writeln('CITY6_DB_PASSWORD is not set.');
    exitCode = 1;
    return;
  }

  final connection = await Connection.open(
    Endpoint(
      host: 'localhost',
      port: 5432,
      database: 'city6',
      username: 'city6_app',
      password: password,
    ),
    settings: const ConnectionSettings(
      sslMode: SslMode.disable,
    ),
  );

  final repository = PostgresRideRequestRepository(
    database: connection,
  );

  try {
    await _cleanup(connection);

    await _checkCompletionWithoutReservation(
      connection,
      repository,
    );

    await _cleanup(connection);

    await _checkCompletionPromotesReservedRide(
      connection,
      repository,
    );

    print('');
    print('PostgreSQL atomic ride completion check OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _checkCompletionWithoutReservation(
  Session database,
  PostgresRideRequestRepository repository,
) async {
  print('');
  print('SCENARIO 1: complete City6 ride without reserved next ride');

  const driverId = 'driver-completion-check-1';
  const vehicleId = 'vehicle-completion-check-1';
  const shiftId = 'shift-completion-check-1';
  const rideId = 'ride-completion-check-1';

  final startedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 45));
  final completedAt = DateTime.now().toUtc();

  await _createBusyDriver(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: startedAt,
  );

  await _createCurrentRide(
    database,
    rideId: rideId,
    driverId: driverId,
    vehicleId: vehicleId,
    requestedAt: startedAt.add(const Duration(minutes: 5)),
  );

  final currentRide = await repository.findById(rideId);

  if (currentRide == null) {
    throw StateError('Current ride was not found.');
  }

  final completedRide = currentRide
      .copyWith(
        meterFareMinor: 2450,
        commissionRateBps: 1000,
        commissionAmountMinor: 245,
        completedByDriverId: driverId,
        completedAt: completedAt,
      )
      .transitionTo(RideRequestStatus.completed);

  final result = await repository.completeRideAndPromoteReservedRide(
    completedRide: completedRide,
  );

  if (result.status != RideRequestStatus.completed) {
    throw StateError('Current ride was not completed.');
  }

  if (result.meterFareMinor != 2450 ||
      result.commissionRateBps != 1000 ||
      result.commissionAmountMinor != 245 ||
      result.completedByDriverId != driverId ||
      result.completedAt != completedAt) {
    throw StateError('Completion money/audit data was not persisted correctly.');
  }

  final queue = await _readQueue(database, shiftId);

  if (queue['availability'] != 'available') {
    throw StateError(
      'Driver did not become available after completion without reservation.',
    );
  }

  final priorityAfter =
      (queue['queue_priority_since'] as DateTime).toUtc();

  if (priorityAfter != completedAt) {
    throw StateError(
      'Queue priority was not reset to completion time.',
    );
  }

  print('current ride -> completed: OK');
  print('fare + commission persisted: OK');
  print('queue -> available: OK');
  print('queue priority reset to completion time: OK');
}

Future<void> _checkCompletionPromotesReservedRide(
  Session database,
  PostgresRideRequestRepository repository,
) async {
  print('');
  print('SCENARIO 2: completion promotes an existing reserved next ride');

  const driverId = 'driver-completion-check-2';
  const vehicleId = 'vehicle-completion-check-2';
  const shiftId = 'shift-completion-check-2';
  const currentRideId = 'ride-completion-check-2-current';
  const reservedRideId = 'ride-completion-check-2-reserved';
  const reservationId = 'reservation-completion-check-2';

  final startedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 50));
  final originalPriority = startedAt.add(const Duration(minutes: 2));
  final reservedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 4));
  final completedAt = DateTime.now().toUtc();

  await _createBusyDriver(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: startedAt,
    queuePrioritySince: originalPriority,
  );

  await _createCurrentRide(
    database,
    rideId: currentRideId,
    driverId: driverId,
    vehicleId: vehicleId,
    requestedAt: startedAt.add(const Duration(minutes: 5)),
  );

  await _createReservedRide(
    database,
    rideId: reservedRideId,
    requestedAt: startedAt.add(const Duration(minutes: 20)),
  );

  await database.execute(
    Sql.named('''
      INSERT INTO ride_reservations (
        id,
        ride_id,
        driver_id,
        vehicle_id,
        shift_id,
        reserved_at,
        ended_at
      )
      VALUES (
        @id,
        @rideId,
        @driverId,
        @vehicleId,
        @shiftId,
        @reservedAt,
        NULL
      )
    '''),
    parameters: {
      'id': reservationId,
      'rideId': reservedRideId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'shiftId': shiftId,
      'reservedAt': reservedAt,
    },
  );

  final currentRide = await repository.findById(currentRideId);

  if (currentRide == null) {
    throw StateError('Current ride was not found.');
  }

  final completedRide = currentRide
      .copyWith(
        meterFareMinor: 3675,
        commissionRateBps: 1000,
        commissionAmountMinor: 368,
        completedByDriverId: driverId,
        completedAt: completedAt,
      )
      .transitionTo(RideRequestStatus.completed);

  final result = await repository.completeRideAndPromoteReservedRide(
    completedRide: completedRide,
  );

  if (result.status != RideRequestStatus.completed) {
    throw StateError('Current ride was not completed.');
  }

  final nextRide = await _readRide(database, reservedRideId);

  if (nextRide['status'] != 'accepted') {
    throw StateError('Reserved next ride was not promoted to accepted.');
  }

  if (nextRide['assigned_driver_id'] != driverId ||
      nextRide['assigned_vehicle_id'] != vehicleId) {
    throw StateError(
      'Promoted ride did not receive the correct driver/vehicle.',
    );
  }

  if (nextRide['driver_bonus_minor'] != 500 ||
      nextRide['dispatch_round'] != 2 ||
      nextRide['bonus_decision'] != 'accepted') {
    throw StateError('+5 dispatch state was not preserved.');
  }

  final reservation = await _readReservation(
    database,
    reservationId,
  );

  final endedAt = (reservation['ended_at'] as DateTime?)?.toUtc();

  if (endedAt != completedAt) {
    throw StateError('Reservation was not ended at completion time.');
  }

  final queue = await _readQueue(database, shiftId);

  if (queue['availability'] != 'busy') {
    throw StateError(
      'Queue became free even though the next ride was promoted.',
    );
  }

  final priorityAfter =
      (queue['queue_priority_since'] as DateTime).toUtc();

  if (priorityAfter != originalPriority) {
    throw StateError(
      'Promoting a reserved ride unexpectedly changed queue priority.',
    );
  }

  print('current ride -> completed: OK');
  print('reserved next ride -> accepted: OK');
  print('assigned driver/vehicle populated: OK');
  print('reservation ended: OK');
  print('+5 dispatch state preserved: OK');
  print('queue remains busy: OK');
  print('queue priority preserved while staying busy: OK');
}

Future<void> _createBusyDriver(
  Session database, {
  required String driverId,
  required String vehicleId,
  required String shiftId,
  required DateTime startedAt,
  DateTime? queuePrioritySince,
}) async {
  await database.execute(
    Sql.named('''
      INSERT INTO drivers (
        id,
        username,
        password_hash,
        first_name,
        last_name,
        phone,
        is_active,
        created_at
      )
      VALUES (
        @id,
        @username,
        'test-only-hash',
        'Completion',
        'Check',
        @phone,
        TRUE,
        @createdAt
      )
    '''),
    parameters: {
      'id': driverId,
      'username': '${driverId}_username',
      'phone': '${driverId}_phone',
      'createdAt': startedAt,
    },
  );

  await database.execute(
    Sql.named('''
      INSERT INTO vehicles (
        id,
        plate_number,
        is_active,
        created_at
      )
      VALUES (
        @id,
        @plateNumber,
        TRUE,
        @createdAt
      )
    '''),
    parameters: {
      'id': vehicleId,
      'plateNumber': vehicleId.toUpperCase(),
      'createdAt': startedAt,
    },
  );

  await database.execute(
    Sql.named('''
      INSERT INTO driver_shifts (
        id,
        driver_id,
        vehicle_id,
        started_at,
        protected_breaks_used
      )
      VALUES (
        @id,
        @driverId,
        @vehicleId,
        @startedAt,
        0
      )
    '''),
    parameters: {
      'id': shiftId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'startedAt': startedAt,
    },
  );

  await database.execute(
    Sql.named('''
      INSERT INTO driver_queue_states (
        shift_id,
        availability,
        queue_priority_since,
        break_started_at,
        has_pending_offer
      )
      VALUES (
        @shiftId,
        'busy',
        @queuePrioritySince,
        NULL,
        FALSE
      )
    '''),
    parameters: {
      'shiftId': shiftId,
      'queuePrioritySince': queuePrioritySince ?? startedAt,
    },
  );
}

Future<void> _createCurrentRide(
  Session database, {
  required String rideId,
  required String driverId,
  required String vehicleId,
  required DateTime requestedAt,
}) async {
  await database.execute(
    Sql.named('''
      INSERT INTO rides (
        id,
        pickup,
        destination,
        passengers,
        has_luggage,
        requested_at,
        status,
        assigned_driver_id,
        assigned_vehicle_id,
        dispatch_round,
        driver_bonus_minor,
        bonus_decision,
        currency
      )
      VALUES (
        @id,
        'Completion current pickup',
        'Completion current destination',
        1,
        FALSE,
        @requestedAt,
        'inProgress',
        @driverId,
        @vehicleId,
        1,
        0,
        'not_offered',
        'EUR'
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': requestedAt,
      'driverId': driverId,
      'vehicleId': vehicleId,
    },
  );
}

Future<void> _createReservedRide(
  Session database, {
  required String rideId,
  required DateTime requestedAt,
}) async {
  await database.execute(
    Sql.named('''
      INSERT INTO rides (
        id,
        pickup,
        destination,
        passengers,
        has_luggage,
        requested_at,
        status,
        assigned_driver_id,
        assigned_vehicle_id,
        dispatch_round,
        driver_bonus_minor,
        bonus_decision,
        currency
      )
      VALUES (
        @id,
        'Completion reserved pickup',
        'Completion reserved destination',
        2,
        TRUE,
        @requestedAt,
        'reserved',
        NULL,
        NULL,
        2,
        500,
        'accepted',
        'EUR'
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': requestedAt,
    },
  );
}

Future<Map<String, dynamic>> _readRide(
  Session database,
  String rideId,
) async {
  final result = await database.execute(
    Sql.named('''
      SELECT
        status,
        assigned_driver_id,
        assigned_vehicle_id,
        dispatch_round,
        driver_bonus_minor,
        bonus_decision,
        meter_fare_minor,
        commission_rate_bps,
        commission_amount_minor,
        completed_by_driver_id,
        completed_at
      FROM rides
      WHERE id = @rideId
    '''),
    parameters: {
      'rideId': rideId,
    },
  );

  if (result.length != 1) {
    throw StateError('Ride $rideId was not found.');
  }

  return result.single.toColumnMap();
}

Future<Map<String, dynamic>> _readReservation(
  Session database,
  String reservationId,
) async {
  final result = await database.execute(
    Sql.named('''
      SELECT
        id,
        ride_id,
        driver_id,
        vehicle_id,
        shift_id,
        reserved_at,
        ended_at
      FROM ride_reservations
      WHERE id = @reservationId
    '''),
    parameters: {
      'reservationId': reservationId,
    },
  );

  if (result.length != 1) {
    throw StateError('Reservation $reservationId was not found.');
  }

  return result.single.toColumnMap();
}

Future<Map<String, dynamic>> _readQueue(
  Session database,
  String shiftId,
) async {
  final result = await database.execute(
    Sql.named('''
      SELECT
        availability,
        queue_priority_since,
        break_started_at,
        has_pending_offer
      FROM driver_queue_states
      WHERE shift_id = @shiftId
    '''),
    parameters: {
      'shiftId': shiftId,
    },
  );

  if (result.length != 1) {
    throw StateError('Queue state $shiftId was not found.');
  }

  return result.single.toColumnMap();
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
    DELETE FROM ride_reservations
    WHERE driver_id LIKE 'driver-completion-check-%'
       OR ride_id LIKE 'ride-completion-check-%'
  ''');

  await database.execute('''
    DELETE FROM ride_offers
    WHERE driver_id LIKE 'driver-completion-check-%'
       OR ride_id LIKE 'ride-completion-check-%'
  ''');

  await database.execute('''
    DELETE FROM rides
    WHERE id LIKE 'ride-completion-check-%'
  ''');

  await database.execute('''
    DELETE FROM driver_queue_states
    WHERE shift_id LIKE 'shift-completion-check-%'
  ''');

  await database.execute('''
    DELETE FROM driver_shifts
    WHERE id LIKE 'shift-completion-check-%'
  ''');

  await database.execute('''
    DELETE FROM vehicles
    WHERE id LIKE 'vehicle-completion-check-%'
  ''');

  await database.execute('''
    DELETE FROM drivers
    WHERE id LIKE 'driver-completion-check-%'
  ''');
}

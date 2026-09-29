import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_reservation_repository.dart';
import 'package:postgres/postgres.dart';

Future<void> main() async {
  final password = Platform.environment['CITY6_DB_PASSWORD'];

  if (password == null || password.isEmpty) {
    stderr.writeln('CITY6_DB_PASSWORD is not set.');
    exitCode = 1;
    return;
  }

  final connectionA = await _openConnection(password);
  final connectionB = await _openConnection(password);

  final repositoryA = PostgresAtomicRideReservationRepository(
    database: connectionA,
  );

  final repositoryB = PostgresAtomicRideReservationRepository(
    database: connectionB,
  );

  try {
    await _cleanup(connectionA);

    await _checkTwoDriversRaceSameRide(
      connectionA,
      repositoryA,
      repositoryB,
    );

    await _checkSameDriverRacesTwoRides(
      connectionA,
      repositoryA,
      repositoryB,
    );

    print('');
    print('PostgreSQL atomic ride reservation race check OK');
  } finally {
    await _cleanup(connectionA);

    await connectionB.close();
    await connectionA.close();
  }
}

Future<Connection> _openConnection(String password) {
  return Connection.open(
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
}

Future<void> _checkTwoDriversRaceSameRide(
  Session setupDatabase,
  PostgresAtomicRideReservationRepository repositoryA,
  PostgresAtomicRideReservationRepository repositoryB,
) async {
  print('');
  print('SCENARIO 1: two drivers race the same waiting ride');

  const rideId = 'ride-reservation-race-1';

  const driverA = 'driver-reservation-race-1a';
  const vehicleA = 'vehicle-reservation-race-1a';
  const shiftA = 'shift-reservation-race-1a';
  const sessionA = 'external-reservation-race-1a';

  const driverB = 'driver-reservation-race-1b';
  const vehicleB = 'vehicle-reservation-race-1b';
  const shiftB = 'shift-reservation-race-1b';
  const sessionB = 'external-reservation-race-1b';

  final now = DateTime.now().toUtc();

  await _createExternalRideDriver(
    setupDatabase,
    driverId: driverA,
    vehicleId: vehicleA,
    shiftId: shiftA,
    sessionId: sessionA,
    startedAt: now.subtract(const Duration(minutes: 30)),
  );

  await _createExternalRideDriver(
    setupDatabase,
    driverId: driverB,
    vehicleId: vehicleB,
    shiftId: shiftB,
    sessionId: sessionB,
    startedAt: now.subtract(const Duration(minutes: 30)),
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: rideId,
  );

  final outcomes = await Future.wait([
    _attemptReservation(
      repositoryA,
      reservationId: 'reservation-race-1a',
      rideId: rideId,
      driverId: driverA,
      now: now,
    ),
    _attemptReservation(
      repositoryB,
      reservationId: 'reservation-race-1b',
      rideId: rideId,
      driverId: driverB,
      now: now,
    ),
  ]);

  final successCount = outcomes.where((outcome) => outcome == null).length;

  final conflicts = outcomes
      .whereType<AtomicRideReservationConflict>()
      .toList();

  if (successCount != 1 || conflicts.length != 1) {
    throw StateError(
      'Expected exactly one success and one conflict. '
      'Outcomes: $outcomes',
    );
  }

  if (conflicts.single !=
      AtomicRideReservationConflict.rideNotWaitingForVehicle) {
    throw StateError(
      'Expected losing driver to see rideNotWaitingForVehicle, '
      'got ${conflicts.single}.',
    );
  }

  final ride = await _readRide(
    setupDatabase,
    rideId,
  );

  if (ride['status'] != 'reserved') {
    throw StateError(
      'Race winner did not leave ride reserved.',
    );
  }

  if (ride['assigned_driver_id'] != null ||
      ride['assigned_vehicle_id'] != null) {
    throw StateError(
      'Race populated assigned_* on reserved ride.',
    );
  }

  final reservations = await _readActiveReservationsForRide(
    setupDatabase,
    rideId,
  );

  if (reservations.length != 1) {
    throw StateError(
      'Expected exactly one active reservation for raced ride.',
    );
  }

  final winningDriver = reservations.single['driver_id'];

  if (winningDriver != driverA && winningDriver != driverB) {
    throw StateError(
      'Unexpected winning driver: $winningDriver.',
    );
  }

  print('exactly one driver wins: OK');
  print('loser sees rideNotWaitingForVehicle: OK');
  print('exactly one active reservation exists: OK');
  print('reserved ride assigned_* remain NULL: OK');
}

Future<void> _checkSameDriverRacesTwoRides(
  Session setupDatabase,
  PostgresAtomicRideReservationRepository repositoryA,
  PostgresAtomicRideReservationRepository repositoryB,
) async {
  print('');
  print('SCENARIO 2: same driver races two waiting rides');

  const driverId = 'driver-reservation-race-2';
  const vehicleId = 'vehicle-reservation-race-2';
  const shiftId = 'shift-reservation-race-2';
  const sessionId = 'external-reservation-race-2';

  const rideA = 'ride-reservation-race-2a';
  const rideB = 'ride-reservation-race-2b';

  final now = DateTime.now().toUtc();

  await _createExternalRideDriver(
    setupDatabase,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    sessionId: sessionId,
    startedAt: now.subtract(const Duration(minutes: 30)),
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: rideA,
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: rideB,
  );

  final outcomes = await Future.wait([
    _attemptReservation(
      repositoryA,
      reservationId: 'reservation-race-2a',
      rideId: rideA,
      driverId: driverId,
      now: now,
    ),
    _attemptReservation(
      repositoryB,
      reservationId: 'reservation-race-2b',
      rideId: rideB,
      driverId: driverId,
      now: now,
    ),
  ]);

  final successCount = outcomes.where((outcome) => outcome == null).length;

  final conflicts = outcomes
      .whereType<AtomicRideReservationConflict>()
      .toList();

  if (successCount != 1 || conflicts.length != 1) {
    throw StateError(
      'Expected exactly one success and one conflict. '
      'Outcomes: $outcomes',
    );
  }

  if (conflicts.single !=
      AtomicRideReservationConflict.driverAlreadyHasReservedRide) {
    throw StateError(
      'Expected driverAlreadyHasReservedRide, '
      'got ${conflicts.single}.',
    );
  }

  final firstRide = await _readRide(
    setupDatabase,
    rideA,
  );

  final secondRide = await _readRide(
    setupDatabase,
    rideB,
  );

  final statuses = <String>[
    firstRide['status'] as String,
    secondRide['status'] as String,
  ];

  final reservedCount = statuses.where(
    (status) => status == 'reserved',
  ).length;

  final waitingCount = statuses.where(
    (status) => status == 'waitingForVehicle',
  ).length;

  if (reservedCount != 1 || waitingCount != 1) {
    throw StateError(
      'Expected one reserved ride and one waiting ride. '
      'Statuses: $statuses',
    );
  }

  final reservationCount = await _countActiveReservationsForDriver(
    setupDatabase,
    driverId,
  );

  if (reservationCount != 1) {
    throw StateError(
      'Expected exactly one active reservation for driver.',
    );
  }

  print('exactly one reservation succeeds: OK');
  print('second attempt sees driverAlreadyHasReservedRide: OK');
  print('one ride reserved + one ride waiting: OK');
  print('driver has exactly one active reservation: OK');
}

Future<AtomicRideReservationConflict?> _attemptReservation(
  PostgresAtomicRideReservationRepository repository, {
  required String reservationId,
  required String rideId,
  required String driverId,
  required DateTime now,
}) async {
  try {
    await repository.reserveWaitingRide(
      reservationId: reservationId,
      rideId: rideId,
      driverId: driverId,
      combinedEtaSeconds: 300,
      now: now,
    );

    return null;
  } on AtomicRideReservationConflictException catch (error) {
    return error.conflict;
  }
}

Future<void> _createExternalRideDriver(
  Session database, {
  required String driverId,
  required String vehicleId,
  required String shiftId,
  required String sessionId,
  required DateTime startedAt,
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
        'Reservation',
        'Race',
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
        'externalRide',
        @queuePrioritySince,
        NULL,
        FALSE
      )
    '''),
    parameters: {
      'shiftId': shiftId,
      'queuePrioritySince': startedAt,
    },
  );

  await database.execute(
    Sql.named('''
      INSERT INTO external_ride_sessions (
        id,
        driver_id,
        started_at,
        ended_at,
        distance_meters,
        trigger_offer_id,
        trigger_ride_id
      )
      VALUES (
        @id,
        @driverId,
        @startedAt,
        NULL,
        700,
        NULL,
        NULL
      )
    '''),
    parameters: {
      'id': sessionId,
      'driverId': driverId,
      'startedAt': startedAt,
    },
  );
}

Future<void> _createWaitingRide(
  Session database, {
  required String rideId,
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
        dispatch_round,
        driver_bonus_minor,
        bonus_decision,
        currency
      )
      VALUES (
        @id,
        'Reservation race pickup',
        'Reservation race destination',
        1,
        FALSE,
        @requestedAt,
        'waitingForVehicle',
        1,
        0,
        'not_offered',
        'EUR'
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': DateTime.now().toUtc(),
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
        assigned_vehicle_id
      FROM rides
      WHERE id = @rideId
    '''),
    parameters: {
      'rideId': rideId,
    },
  );

  if (result.length != 1) {
    throw StateError(
      'Ride $rideId was not found.',
    );
  }

  return result.single.toColumnMap();
}

Future<List<Map<String, dynamic>>> _readActiveReservationsForRide(
  Session database,
  String rideId,
) async {
  final result = await database.execute(
    Sql.named('''
      SELECT
        id,
        ride_id,
        driver_id,
        vehicle_id,
        shift_id
      FROM ride_reservations
      WHERE ride_id = @rideId
        AND ended_at IS NULL
    '''),
    parameters: {
      'rideId': rideId,
    },
  );

  return result
      .map((row) => row.toColumnMap())
      .toList();
}

Future<int> _countActiveReservationsForDriver(
  Session database,
  String driverId,
) async {
  final result = await database.execute(
    Sql.named('''
      SELECT COUNT(*) AS reservation_count
      FROM ride_reservations
      WHERE driver_id = @driverId
        AND ended_at IS NULL
    '''),
    parameters: {
      'driverId': driverId,
    },
  );

  return result.single.toColumnMap()['reservation_count'] as int;
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
    DELETE FROM ride_reservations
    WHERE driver_id LIKE 'driver-reservation-race-%'
       OR ride_id LIKE 'ride-reservation-race-%'
  ''');

  await database.execute('''
    DELETE FROM external_ride_sessions
    WHERE driver_id LIKE 'driver-reservation-race-%'
  ''');

  await database.execute('''
    DELETE FROM ride_offers
    WHERE driver_id LIKE 'driver-reservation-race-%'
       OR ride_id LIKE 'ride-reservation-race-%'
  ''');

  await database.execute('''
    DELETE FROM rides
    WHERE id LIKE 'ride-reservation-race-%'
  ''');

  await database.execute('''
    DELETE FROM driver_queue_states
    WHERE shift_id LIKE 'shift-reservation-race-%'
  ''');

  await database.execute('''
    DELETE FROM driver_shifts
    WHERE id LIKE 'shift-reservation-race-%'
  ''');

  await database.execute('''
    DELETE FROM vehicles
    WHERE id LIKE 'vehicle-reservation-race-%'
  ''');

  await database.execute('''
    DELETE FROM drivers
    WHERE id LIKE 'driver-reservation-race-%'
  ''');
}
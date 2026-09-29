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

  final repository = PostgresAtomicRideReservationRepository(
    database: connection,
  );

  try {
    await _cleanup(connection);

    await _checkExternalRide499Denied(
      connection,
      repository,
    );

    await _checkExternalRide500AllowedAndBonusPreserved(
      connection,
      repository,
    );

    await _checkEtaAbove600Denied(
      connection,
      repository,
    );

    await _checkSecondReservationForDriverDenied(
      connection,
      repository,
    );

    await _checkBusyCity6DriverCanReserve(
      connection,
      repository,
    );

    print('');
    print('PostgreSQL atomic ride reservation check OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _checkExternalRide499Denied(
  Session database,
  PostgresAtomicRideReservationRepository repository,
) async {
  print('');
  print('SCENARIO 1: externalRide 499 m -> reservation denied');

  const driverId = 'driver-atomic-reservation-1';
  const vehicleId = 'vehicle-atomic-reservation-1';
  const shiftId = 'shift-atomic-reservation-1';
  const sessionId = 'external-atomic-reservation-1';
  const rideId = 'ride-atomic-reservation-1';
  const reservationId = 'reservation-atomic-1';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(
      const Duration(minutes: 30),
    ),
    availability: 'externalRide',
  );

  await _createExternalRideSession(
    database,
    sessionId: sessionId,
    driverId: driverId,
    startedAt: now.subtract(
      const Duration(minutes: 20),
    ),
    distanceMeters: 499,
  );

  await _createWaitingRide(
    database,
    rideId: rideId,
    withFiveEuroBonus: false,
  );

  AtomicRideReservationConflict? conflict;

  try {
    await repository.reserveWaitingRide(
      reservationId: reservationId,
      rideId: rideId,
      driverId: driverId,
      combinedEtaSeconds: 300,
      now: now,
    );
  } on AtomicRideReservationConflictException catch (error) {
    conflict = error.conflict;
  }

  if (conflict !=
      AtomicRideReservationConflict.externalRideNotQualified) {
    throw StateError(
      'Expected externalRideNotQualified, got $conflict.',
    );
  }

  final ride = await _readRide(database, rideId);

  if (ride['status'] != 'waitingForVehicle') {
    throw StateError(
      '499 m denial changed waiting ride status.',
    );
  }

  if (await _countActiveReservations(
        database,
        driverId: driverId,
      ) !=
      0) {
    throw StateError(
      '499 m denial created a reservation.',
    );
  }

  print('499 m -> externalRideNotQualified: OK');
  print('ride remains waitingForVehicle: OK');
  print('no reservation created: OK');
}

Future<void> _checkExternalRide500AllowedAndBonusPreserved(
  Session database,
  PostgresAtomicRideReservationRepository repository,
) async {
  print('');
  print(
    'SCENARIO 2: externalRide 500 m + valid ETA -> reserve + preserve +5',
  );

  const driverId = 'driver-atomic-reservation-2';
  const vehicleId = 'vehicle-atomic-reservation-2';
  const shiftId = 'shift-atomic-reservation-2';
  const sessionId = 'external-atomic-reservation-2';
  const rideId = 'ride-atomic-reservation-2';
  const reservationId = 'reservation-atomic-2';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(
      const Duration(minutes: 30),
    ),
    availability: 'externalRide',
  );

  await _createExternalRideSession(
    database,
    sessionId: sessionId,
    driverId: driverId,
    startedAt: now.subtract(
      const Duration(minutes: 20),
    ),
    distanceMeters: 500,
  );

  await _createWaitingRide(
    database,
    rideId: rideId,
    withFiveEuroBonus: true,
  );

  final reservation = await repository.reserveWaitingRide(
    reservationId: reservationId,
    rideId: rideId,
    driverId: driverId,
    combinedEtaSeconds: 600,
    now: now,
  );

  if (!reservation.isActive ||
      reservation.id != reservationId ||
      reservation.rideId != rideId ||
      reservation.driverId != driverId ||
      reservation.vehicleId != vehicleId ||
      reservation.shiftId != shiftId) {
    throw StateError(
      'Returned reservation does not match.',
    );
  }

  final ride = await _readRide(database, rideId);

  if (ride['status'] != 'reserved') {
    throw StateError(
      'Waiting ride was not changed to reserved.',
    );
  }

  if (ride['assigned_driver_id'] != null ||
      ride['assigned_vehicle_id'] != null) {
    throw StateError(
      'Reserved ride incorrectly populated assigned_* fields.',
    );
  }

  if (ride['dispatch_round'] != 2 ||
      ride['driver_bonus_minor'] != 500 ||
      ride['bonus_decision'] != 'accepted') {
    throw StateError(
      'Reservation changed the +5 EUR bonus state.',
    );
  }

  if (await _countActiveReservations(
        database,
        driverId: driverId,
      ) !=
      1) {
    throw StateError(
      'Expected exactly one active reservation.',
    );
  }

  print('exactly 500 m qualifies: OK');
  print('ETA exactly 600 sec qualifies: OK');
  print('ride -> reserved: OK');
  print('assigned_driver_id remains NULL: OK');
  print('assigned_vehicle_id remains NULL: OK');
  print('+5 EUR bonus preserved: OK');
  print('one active reservation created: OK');
}

Future<void> _checkEtaAbove600Denied(
  Session database,
  PostgresAtomicRideReservationRepository repository,
) async {
  print('');
  print('SCENARIO 3: ETA 601 sec -> reservation denied');

  const driverId = 'driver-atomic-reservation-3';
  const vehicleId = 'vehicle-atomic-reservation-3';
  const shiftId = 'shift-atomic-reservation-3';
  const sessionId = 'external-atomic-reservation-3';
  const rideId = 'ride-atomic-reservation-3';
  const reservationId = 'reservation-atomic-3';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(
      const Duration(minutes: 30),
    ),
    availability: 'externalRide',
  );

  await _createExternalRideSession(
    database,
    sessionId: sessionId,
    driverId: driverId,
    startedAt: now.subtract(
      const Duration(minutes: 20),
    ),
    distanceMeters: 700,
  );

  await _createWaitingRide(
    database,
    rideId: rideId,
    withFiveEuroBonus: false,
  );

  AtomicRideReservationConflict? conflict;

  try {
    await repository.reserveWaitingRide(
      reservationId: reservationId,
      rideId: rideId,
      driverId: driverId,
      combinedEtaSeconds: 601,
      now: now,
    );
  } on AtomicRideReservationConflictException catch (error) {
    conflict = error.conflict;
  }

  if (conflict != AtomicRideReservationConflict.etaTooHigh) {
    throw StateError(
      'Expected etaTooHigh, got $conflict.',
    );
  }

  final ride = await _readRide(database, rideId);

  if (ride['status'] != 'waitingForVehicle') {
    throw StateError(
      'ETA denial changed waiting ride status.',
    );
  }

  if (await _countActiveReservations(
        database,
        driverId: driverId,
      ) !=
      0) {
    throw StateError(
      'ETA denial created a reservation.',
    );
  }

  print('601 sec -> etaTooHigh: OK');
  print('ride remains waitingForVehicle: OK');
  print('no reservation created: OK');
}

Future<void> _checkSecondReservationForDriverDenied(
  Session database,
  PostgresAtomicRideReservationRepository repository,
) async {
  print('');
  print('SCENARIO 4: same driver cannot reserve a second ride');

  const driverId = 'driver-atomic-reservation-4';
  const vehicleId = 'vehicle-atomic-reservation-4';
  const shiftId = 'shift-atomic-reservation-4';
  const sessionId = 'external-atomic-reservation-4';

  const firstRideId = 'ride-atomic-reservation-4a';
  const secondRideId = 'ride-atomic-reservation-4b';

  const firstReservationId = 'reservation-atomic-4a';
  const secondReservationId = 'reservation-atomic-4b';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(
      const Duration(minutes: 30),
    ),
    availability: 'externalRide',
  );

  await _createExternalRideSession(
    database,
    sessionId: sessionId,
    driverId: driverId,
    startedAt: now.subtract(
      const Duration(minutes: 20),
    ),
    distanceMeters: 900,
  );

  await _createWaitingRide(
    database,
    rideId: firstRideId,
    withFiveEuroBonus: false,
  );

  await _createWaitingRide(
    database,
    rideId: secondRideId,
    withFiveEuroBonus: false,
  );

  await repository.reserveWaitingRide(
    reservationId: firstReservationId,
    rideId: firstRideId,
    driverId: driverId,
    combinedEtaSeconds: 300,
    now: now,
  );

  AtomicRideReservationConflict? conflict;

  try {
    await repository.reserveWaitingRide(
      reservationId: secondReservationId,
      rideId: secondRideId,
      driverId: driverId,
      combinedEtaSeconds: 300,
      now: now.add(
        const Duration(seconds: 1),
      ),
    );
  } on AtomicRideReservationConflictException catch (error) {
    conflict = error.conflict;
  }

  if (conflict !=
      AtomicRideReservationConflict.driverAlreadyHasReservedRide) {
    throw StateError(
      'Expected driverAlreadyHasReservedRide, got $conflict.',
    );
  }

  final secondRide = await _readRide(
    database,
    secondRideId,
  );

  if (secondRide['status'] != 'waitingForVehicle') {
    throw StateError(
      'Second ride status changed after denied reservation.',
    );
  }

  if (await _countActiveReservations(
        database,
        driverId: driverId,
      ) !=
      1) {
    throw StateError(
      'Driver should still have exactly one reservation.',
    );
  }

  print('second reservation denied: OK');
  print('second ride remains waitingForVehicle: OK');
  print('driver still has exactly one active reservation: OK');
}

Future<void> _checkBusyCity6DriverCanReserve(
  Session database,
  PostgresAtomicRideReservationRepository repository,
) async {
  print('');
  print('SCENARIO 5: City6 busy driver can reserve next ride');

  const driverId = 'driver-atomic-reservation-5';
  const vehicleId = 'vehicle-atomic-reservation-5';
  const shiftId = 'shift-atomic-reservation-5';

  const currentRideId = 'ride-atomic-reservation-5-current';
  const nextRideId = 'ride-atomic-reservation-5-next';
  const reservationId = 'reservation-atomic-5';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(
      const Duration(minutes: 40),
    ),
    availability: 'busy',
  );

  await _createCurrentCity6Ride(
    database,
    rideId: currentRideId,
    driverId: driverId,
    vehicleId: vehicleId,
  );

  await _createWaitingRide(
    database,
    rideId: nextRideId,
    withFiveEuroBonus: false,
  );

  final reservation = await repository.reserveWaitingRide(
    reservationId: reservationId,
    rideId: nextRideId,
    driverId: driverId,
    combinedEtaSeconds: 540,
    now: now,
  );

  if (!reservation.isActive ||
      reservation.driverId != driverId ||
      reservation.vehicleId != vehicleId ||
      reservation.shiftId != shiftId ||
      reservation.rideId != nextRideId) {
    throw StateError(
      'Busy-driver reservation does not match.',
    );
  }

  final nextRide = await _readRide(
    database,
    nextRideId,
  );

  if (nextRide['status'] != 'reserved') {
    throw StateError(
      'Busy driver did not reserve next ride.',
    );
  }

  if (nextRide['assigned_driver_id'] != null ||
      nextRide['assigned_vehicle_id'] != null) {
    throw StateError(
      'Busy-driver reservation populated assigned_* fields.',
    );
  }

  final currentRide = await _readRide(
    database,
    currentRideId,
  );

  if (currentRide['status'] != 'inProgress' ||
      currentRide['assigned_driver_id'] != driverId ||
      currentRide['assigned_vehicle_id'] != vehicleId) {
    throw StateError(
      'Current City6 ride was changed by reservation.',
    );
  }

  print('busy City6 driver reservation succeeds: OK');
  print('current ride remains inProgress: OK');
  print('next ride -> reserved: OK');
  print('next ride assigned_* remain NULL: OK');
}

Future<void> _createDriverVehicleAndShift(
  Session database, {
  required String driverId,
  required String vehicleId,
  required String shiftId,
  required DateTime startedAt,
  required String availability,
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
        'Atomic',
        'Reservation',
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
        @availability,
        @queuePrioritySince,
        NULL,
        FALSE
      )
    '''),
    parameters: {
      'shiftId': shiftId,
      'availability': availability,
      'queuePrioritySince': startedAt,
    },
  );
}

Future<void> _createExternalRideSession(
  Session database, {
  required String sessionId,
  required String driverId,
  required DateTime startedAt,
  required int distanceMeters,
}) async {
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
        @distanceMeters,
        NULL,
        NULL
      )
    '''),
    parameters: {
      'id': sessionId,
      'driverId': driverId,
      'startedAt': startedAt,
      'distanceMeters': distanceMeters,
    },
  );
}

Future<void> _createWaitingRide(
  Session database, {
  required String rideId,
  required bool withFiveEuroBonus,
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
        'Atomic reservation pickup',
        'Atomic reservation destination',
        1,
        FALSE,
        @requestedAt,
        'waitingForVehicle',
        @dispatchRound,
        @driverBonusMinor,
        @bonusDecision,
        'EUR'
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': DateTime.now().toUtc(),
      'dispatchRound': withFiveEuroBonus ? 2 : 1,
      'driverBonusMinor': withFiveEuroBonus ? 500 : 0,
      'bonusDecision': withFiveEuroBonus
          ? 'accepted'
          : 'not_offered',
    },
  );
}

Future<void> _createCurrentCity6Ride(
  Session database, {
  required String rideId,
  required String driverId,
  required String vehicleId,
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
        'Current City6 pickup',
        'Current City6 destination',
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
      'driverId': driverId,
      'vehicleId': vehicleId,
      'requestedAt': DateTime.now().toUtc().subtract(
        const Duration(minutes: 15),
      ),
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
        bonus_decision
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

Future<int> _countActiveReservations(
  Session database, {
  required String driverId,
}) async {
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
    WHERE driver_id LIKE 'driver-atomic-reservation-%'
       OR ride_id LIKE 'ride-atomic-reservation-%'
  ''');

  await database.execute('''
    DELETE FROM external_ride_sessions
    WHERE driver_id LIKE 'driver-atomic-reservation-%'
  ''');

  await database.execute('''
    DELETE FROM ride_offers
    WHERE driver_id LIKE 'driver-atomic-reservation-%'
       OR ride_id LIKE 'ride-atomic-reservation-%'
  ''');

  await database.execute('''
    DELETE FROM rides
    WHERE id LIKE 'ride-atomic-reservation-%'
  ''');

  await database.execute('''
    DELETE FROM driver_queue_states
    WHERE shift_id LIKE 'shift-atomic-reservation-%'
  ''');

  await database.execute('''
    DELETE FROM driver_shifts
    WHERE id LIKE 'shift-atomic-reservation-%'
  ''');

  await database.execute('''
    DELETE FROM vehicles
    WHERE id LIKE 'vehicle-atomic-reservation-%'
  ''');

  await database.execute('''
    DELETE FROM drivers
    WHERE id LIKE 'driver-atomic-reservation-%'
  ''');
}
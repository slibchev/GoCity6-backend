import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_waiting_ride_acceptance_repository.dart';
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

  final repositoryA = PostgresAtomicWaitingRideAcceptanceRepository(
    database: connectionA,
  );

  final repositoryB = PostgresAtomicWaitingRideAcceptanceRepository(
    database: connectionB,
  );

  try {
    await _cleanup(connectionA);

    await _checkAvailableDriverAcceptsWaitingRide(
      connectionA,
      repositoryA,
    );

    await _cleanup(connectionA);

    await _checkSameDriverRacesTwoWaitingRides(
      connectionA,
      repositoryA,
      repositoryB,
    );

    await _cleanup(connectionA);

    await _checkTwoDriversRaceSameWaitingRide(
      connectionA,
      repositoryA,
      repositoryB,
    );

    print('');
    print('PostgreSQL atomic waiting ride acceptance check OK');
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

Future<void> _checkAvailableDriverAcceptsWaitingRide(
  Session setupDatabase,
  PostgresAtomicWaitingRideAcceptanceRepository repository,
) async {
  print('');
  print('SCENARIO 1: available driver accepts waiting ride');

  const driverId = 'driver-waiting-accept-check-1';
  const vehicleId = 'vehicle-waiting-accept-check-1';
  const shiftId = 'shift-waiting-accept-check-1';
  const rideId = 'ride-waiting-accept-check-1';

  final startedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 20));

  final originalPriority = startedAt.add(
    const Duration(minutes: 2),
  );

  await _createAvailableDriver(
    setupDatabase,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: startedAt,
    queuePrioritySince: originalPriority,
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: rideId,
    requestedAt: startedAt.add(const Duration(minutes: 5)),
    dispatchRound: 2,
    driverBonusMinor: 500,
    bonusDecision: 'accepted',
  );

  final acceptedRide = await repository.acceptWaitingRide(
    rideId: rideId,
    driverId: driverId,
  );

  if (acceptedRide.status.name != 'accepted' ||
      acceptedRide.assignedDriverId != driverId ||
      acceptedRide.assignedVehicleId != vehicleId) {
    throw StateError(
      'Waiting ride was not accepted with the active shift assignment.',
    );
  }

  if (acceptedRide.dispatchRound != 2 ||
      acceptedRide.driverBonusMinor != 500 ||
      acceptedRide.bonusDecision.databaseValue != 'accepted') {
    throw StateError('+5 dispatch state was not preserved.');
  }

  final queue = await _readQueue(
    setupDatabase,
    shiftId,
  );

  if (queue['availability'] != 'busy') {
    throw StateError(
      'Accepted board ride did not move queue to busy.',
    );
  }

  final priorityAfter =
      (queue['queue_priority_since'] as DateTime).toUtc();

  if (priorityAfter != originalPriority) {
    throw StateError(
      'Accepting board ride unexpectedly changed queue priority.',
    );
  }

  print('ride -> accepted: OK');
  print('assigned driver/vehicle come from active shift: OK');
  print('+5 dispatch state preserved: OK');
  print('queue available -> busy: OK');
  print('queue priority preserved: OK');
}

Future<void> _checkSameDriverRacesTwoWaitingRides(
  Session setupDatabase,
  PostgresAtomicWaitingRideAcceptanceRepository repositoryA,
  PostgresAtomicWaitingRideAcceptanceRepository repositoryB,
) async {
  print('');
  print('SCENARIO 2: same available driver races two waiting rides');

  const driverId = 'driver-waiting-accept-check-2';
  const vehicleId = 'vehicle-waiting-accept-check-2';
  const shiftId = 'shift-waiting-accept-check-2';
  const rideA = 'ride-waiting-accept-check-2a';
  const rideB = 'ride-waiting-accept-check-2b';

  final startedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 20));

  await _createAvailableDriver(
    setupDatabase,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: startedAt,
    queuePrioritySince: startedAt,
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: rideA,
    requestedAt: startedAt.add(const Duration(minutes: 5)),
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: rideB,
    requestedAt: startedAt.add(const Duration(minutes: 6)),
  );

  final outcomes = await Future.wait([
    _attemptAccept(
      repositoryA,
      rideId: rideA,
      driverId: driverId,
    ),
    _attemptAccept(
      repositoryB,
      rideId: rideB,
      driverId: driverId,
    ),
  ]);

  final successCount =
      outcomes.where((outcome) => outcome == 'success').length;

  final unavailableCount = outcomes.where(
    (outcome) =>
        outcome ==
        'conflict:${AtomicWaitingRideAcceptanceConflict.driverNotAvailable.name}',
  ).length;

  if (successCount != 1 || unavailableCount != 1) {
    throw StateError(
      'Expected one success and one driverNotAvailable conflict. '
      'Outcomes: $outcomes',
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

  final acceptedCount = [firstRide, secondRide]
      .where((ride) => ride['status'] == 'accepted')
      .length;

  final waitingCount = [firstRide, secondRide]
      .where((ride) => ride['status'] == 'waitingForVehicle')
      .length;

  if (acceptedCount != 1 || waitingCount != 1) {
    throw StateError(
      'Expected one accepted ride and one waiting ride.',
    );
  }

  final queue = await _readQueue(
    setupDatabase,
    shiftId,
  );

  if (queue['availability'] != 'busy') {
    throw StateError(
      'Winning acceptance did not leave driver busy.',
    );
  }

  print('exactly one ride is accepted: OK');
  print('second claim sees driverNotAvailable: OK');
  print('other ride remains waiting: OK');
  print('queue remains busy after winner: OK');
}

Future<void> _checkTwoDriversRaceSameWaitingRide(
  Session setupDatabase,
  PostgresAtomicWaitingRideAcceptanceRepository repositoryA,
  PostgresAtomicWaitingRideAcceptanceRepository repositoryB,
) async {
  print('');
  print('SCENARIO 3: two available drivers race the same waiting ride');

  const rideId = 'ride-waiting-accept-check-3';

  const driverA = 'driver-waiting-accept-check-3a';
  const vehicleA = 'vehicle-waiting-accept-check-3a';
  const shiftA = 'shift-waiting-accept-check-3a';

  const driverB = 'driver-waiting-accept-check-3b';
  const vehicleB = 'vehicle-waiting-accept-check-3b';
  const shiftB = 'shift-waiting-accept-check-3b';

  final startedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 20));

  await _createAvailableDriver(
    setupDatabase,
    driverId: driverA,
    vehicleId: vehicleA,
    shiftId: shiftA,
    startedAt: startedAt,
    queuePrioritySince: startedAt,
  );

  await _createAvailableDriver(
    setupDatabase,
    driverId: driverB,
    vehicleId: vehicleB,
    shiftId: shiftB,
    startedAt: startedAt,
    queuePrioritySince: startedAt.add(const Duration(seconds: 1)),
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: rideId,
    requestedAt: startedAt.add(const Duration(minutes: 5)),
  );

  final outcomes = await Future.wait([
    _attemptAccept(
      repositoryA,
      rideId: rideId,
      driverId: driverA,
    ),
    _attemptAccept(
      repositoryB,
      rideId: rideId,
      driverId: driverB,
    ),
  ]);

  final successCount =
      outcomes.where((outcome) => outcome == 'success').length;

  final notWaitingCount = outcomes.where(
    (outcome) =>
        outcome ==
        'conflict:${AtomicWaitingRideAcceptanceConflict.rideNotWaitingForVehicle.name}',
  ).length;

  if (successCount != 1 || notWaitingCount != 1) {
    throw StateError(
      'Expected one success and one rideNotWaitingForVehicle conflict. '
      'Outcomes: $outcomes',
    );
  }

  final ride = await _readRide(
    setupDatabase,
    rideId,
  );

  if (ride['status'] != 'accepted') {
    throw StateError(
      'Raced ride did not end in accepted state.',
    );
  }

  final winningDriver = ride['assigned_driver_id'];
  final winningVehicle = ride['assigned_vehicle_id'];

  final validWinner =
      (winningDriver == driverA && winningVehicle == vehicleA) ||
      (winningDriver == driverB && winningVehicle == vehicleB);

  if (!validWinner) {
    throw StateError(
      'Raced ride has an unexpected assignment.',
    );
  }

  final queueA = await _readQueue(
    setupDatabase,
    shiftA,
  );

  final queueB = await _readQueue(
    setupDatabase,
    shiftB,
  );

  final busyCount = [queueA, queueB]
      .where((queue) => queue['availability'] == 'busy')
      .length;

  final availableCount = [queueA, queueB]
      .where((queue) => queue['availability'] == 'available')
      .length;

  if (busyCount != 1 || availableCount != 1) {
    throw StateError(
      'Expected winner busy and loser still available.',
    );
  }

  print('exactly one driver wins the ride: OK');
  print('loser sees rideNotWaitingForVehicle: OK');
  print('winner queue -> busy: OK');
  print('loser queue remains available: OK');
}

Future<String> _attemptAccept(
  PostgresAtomicWaitingRideAcceptanceRepository repository, {
  required String rideId,
  required String driverId,
}) async {
  try {
    await repository.acceptWaitingRide(
      rideId: rideId,
      driverId: driverId,
    );

    return 'success';
  } on AtomicWaitingRideAcceptanceConflictException catch (error) {
    return 'conflict:${error.conflict.name}';
  }
}

Future<void> _createAvailableDriver(
  Session database, {
  required String driverId,
  required String vehicleId,
  required String shiftId,
  required DateTime startedAt,
  required DateTime queuePrioritySince,
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
        'WaitingRide',
        'Acceptance',
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
        'available',
        @queuePrioritySince,
        NULL,
        FALSE
      )
    '''),
    parameters: {
      'shiftId': shiftId,
      'queuePrioritySince': queuePrioritySince,
    },
  );
}

Future<void> _createWaitingRide(
  Session database, {
  required String rideId,
  required DateTime requestedAt,
  int dispatchRound = 1,
  int driverBonusMinor = 0,
  String bonusDecision = 'not_offered',
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
        'Waiting acceptance pickup',
        'Waiting acceptance destination',
        1,
        FALSE,
        @requestedAt,
        'waitingForVehicle',
        NULL,
        NULL,
        @dispatchRound,
        @driverBonusMinor,
        @bonusDecision,
        'EUR'
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': requestedAt,
      'dispatchRound': dispatchRound,
      'driverBonusMinor': driverBonusMinor,
      'bonusDecision': bonusDecision,
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
    throw StateError(
      'Queue state $shiftId was not found.',
    );
  }

  return result.single.toColumnMap();
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
    DELETE FROM ride_reservations
    WHERE driver_id LIKE 'driver-waiting-accept-check-%'
       OR ride_id LIKE 'ride-waiting-accept-check-%'
  ''');

  await database.execute('''
    DELETE FROM ride_offers
    WHERE driver_id LIKE 'driver-waiting-accept-check-%'
       OR ride_id LIKE 'ride-waiting-accept-check-%'
  ''');

  await database.execute('''
    DELETE FROM rides
    WHERE id LIKE 'ride-waiting-accept-check-%'
  ''');

  await database.execute('''
    DELETE FROM driver_queue_states
    WHERE shift_id LIKE 'shift-waiting-accept-check-%'
  ''');

  await database.execute('''
    DELETE FROM driver_shifts
    WHERE id LIKE 'shift-waiting-accept-check-%'
  ''');

  await database.execute('''
    DELETE FROM vehicles
    WHERE id LIKE 'vehicle-waiting-accept-check-%'
  ''');

  await database.execute('''
    DELETE FROM drivers
    WHERE id LIKE 'driver-waiting-accept-check-%'
  ''');
}

import 'dart:async';
import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/ride/atomic_ride_completion_repository.dart';
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

  final setupConnection = await _openConnection(password);
  final reservationConnection = await _openConnection(password);
  final completionConnection = await _openConnection(password);

  final reservationRepository = PostgresAtomicRideReservationRepository(
    database: reservationConnection,
  );

  final completionRepository = PostgresRideRequestRepository(
    database: completionConnection,
  );

  try {
    await _cleanup(setupConnection);

    await _checkCity6CompletionReservationRace(
      setupConnection,
      reservationRepository,
      completionRepository,
    );

    await _cleanup(setupConnection);

    await _checkCompletionWinsDeterministically(
      setupConnection,
      reservationRepository,
      completionRepository,
    );

    print('');
    print('PostgreSQL City6 completion/reservation race check OK');
  } finally {
    await _cleanup(setupConnection);

    await completionConnection.close();
    await reservationConnection.close();
    await setupConnection.close();
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

Future<void> _checkCity6CompletionReservationRace(
  Session setupDatabase,
  PostgresAtomicRideReservationRepository reservationRepository,
  PostgresRideRequestRepository completionRepository,
) async {
  print('');
  print(
    'SCENARIO 1: City6 completion races waiting-ride reservation',
  );

  const driverId = 'driver-city6-completion-race-1';
  const vehicleId = 'vehicle-city6-completion-race-1';
  const shiftId = 'shift-city6-completion-race-1';
  const currentRideId = 'ride-city6-completion-race-1-current';
  const nextRideId = 'ride-city6-completion-race-1-next';
  const reservationId = 'reservation-city6-completion-race-1';

  final startedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 45));

  final originalPriority = startedAt.add(
    const Duration(minutes: 2),
  );

  final completedAt = DateTime.now().toUtc();

  await _createBusyDriver(
    setupDatabase,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: startedAt,
    queuePrioritySince: originalPriority,
  );

  await _createCurrentRide(
    setupDatabase,
    rideId: currentRideId,
    driverId: driverId,
    vehicleId: vehicleId,
    requestedAt: startedAt.add(const Duration(minutes: 5)),
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: nextRideId,
    requestedAt: startedAt.add(const Duration(minutes: 20)),
  );

  final currentRide = await completionRepository.findById(
    currentRideId,
  );

  if (currentRide == null) {
    throw StateError('Current ride was not found.');
  }

  final completedRide = currentRide
      .copyWith(
        meterFareMinor: 3125,
        commissionRateBps: 1000,
        commissionAmountMinor: 313,
        completedByDriverId: driverId,
        completedAt: completedAt,
      )
      .transitionTo(RideRequestStatus.completed);

  Future<String> reserveNextRide() async {
    try {
      await reservationRepository.reserveWaitingRide(
        reservationId: reservationId,
        rideId: nextRideId,
        driverId: driverId,
        combinedEtaSeconds: 300,
        now: completedAt.subtract(const Duration(seconds: 1)),
      );

      return 'reservationSuccess';
    } on AtomicRideReservationConflictException catch (error) {
      return 'reservationConflict:${error.conflict.name}';
    }
  }

  Future<String> completeCurrentRide() async {
    try {
      await completionRepository.completeRideAndPromoteReservedRide(
        completedRide: completedRide,
      );

      return 'completionSuccess';
    } on AtomicRideCompletionConflictException catch (error) {
      return 'completionConflict:${error.conflict.name}';
    }
  }

  final outcomes = await Future.wait([
    reserveNextRide(),
    completeCurrentRide(),
  ]);

  if (!outcomes.contains('completionSuccess')) {
    throw StateError(
      'City6 completion must succeed safely. Outcomes: $outcomes',
    );
  }

  final currentRideAfter = await _readRide(
    setupDatabase,
    currentRideId,
  );

  if (currentRideAfter['status'] != 'completed' ||
      currentRideAfter['meter_fare_minor'] != 3125 ||
      currentRideAfter['commission_rate_bps'] != 1000 ||
      currentRideAfter['commission_amount_minor'] != 313 ||
      currentRideAfter['completed_by_driver_id'] != driverId ||
      (currentRideAfter['completed_at'] as DateTime?)?.toUtc() !=
          completedAt) {
    throw StateError(
      'Current ride completion data is inconsistent after race.',
    );
  }

  final nextRideAfter = await _readRide(
    setupDatabase,
    nextRideId,
  );

  final queueAfter = await _readQueue(
    setupDatabase,
    shiftId,
  );

  final activeReservations = await _countActiveReservationsForDriver(
    setupDatabase,
    driverId,
  );

  if (activeReservations != 0) {
    throw StateError(
      'Race left an active reservation after current ride completion.',
    );
  }

  if (outcomes.contains('reservationSuccess')) {
    if (nextRideAfter['status'] != 'accepted' ||
        nextRideAfter['assigned_driver_id'] != driverId ||
        nextRideAfter['assigned_vehicle_id'] != vehicleId) {
      throw StateError(
        'Reservation won but next ride was not promoted to accepted. '
        'Outcomes: $outcomes',
      );
    }

    if (nextRideAfter['dispatch_round'] != 2 ||
        nextRideAfter['driver_bonus_minor'] != 500 ||
        nextRideAfter['bonus_decision'] != 'accepted') {
      throw StateError(
        '+5 dispatch state changed during reservation promotion.',
      );
    }

    if (queueAfter['availability'] != 'busy') {
      throw StateError(
        'Reservation won but queue did not remain busy.',
      );
    }

    final priorityAfter =
        (queueAfter['queue_priority_since'] as DateTime).toUtc();

    if (priorityAfter != originalPriority) {
      throw StateError(
        'Reservation won but queue priority changed unexpectedly.',
      );
    }

    final reservation = await _readReservation(
      setupDatabase,
      reservationId,
    );

    if ((reservation['ended_at'] as DateTime?)?.toUtc() != completedAt) {
      throw StateError(
        'Reservation won but was not ended at completion time.',
      );
    }

    print('reservation won -> next ride promoted to accepted: OK');
    print('reservation ended: OK');
    print('+5 dispatch state preserved: OK');
    print('queue remains busy with priority unchanged: OK');
  } else {
    final expectedConflict =
        'reservationConflict:'
        '${AtomicRideReservationConflict.driverNotReservable.name}';

    if (!outcomes.contains(expectedConflict)) {
      throw StateError(
        'Completion won but reservation did not fail with '
        'driverNotReservable. Outcomes: $outcomes',
      );
    }

    if (nextRideAfter['status'] != 'waitingForVehicle' ||
        nextRideAfter['assigned_driver_id'] != null ||
        nextRideAfter['assigned_vehicle_id'] != null) {
      throw StateError(
        'Completion won but waiting ride changed state. '
        'Outcomes: $outcomes',
      );
    }

    if (queueAfter['availability'] != 'available') {
      throw StateError(
        'Completion won but queue did not become available.',
      );
    }

    final priorityAfter =
        (queueAfter['queue_priority_since'] as DateTime).toUtc();

    if (priorityAfter != completedAt) {
      throw StateError(
        'Completion won but queue priority was not reset.',
      );
    }

    final reservationCount = await _countReservationRows(
      setupDatabase,
      reservationId,
    );

    if (reservationCount != 0) {
      throw StateError(
        'Completion won but a reservation row was committed.',
      );
    }

    print('completion won -> reservation safely rejected: OK');
    print('next ride remains waiting and unassigned: OK');
    print('queue -> available with priority reset: OK');
  }

  print('current ride -> completed exactly once: OK');
  print('no active reservation remains: OK');
}


Future<void> _checkCompletionWinsDeterministically(
  Session setupDatabase,
  PostgresAtomicRideReservationRepository reservationRepository,
  PostgresRideRequestRepository completionRepository,
) async {
  print('');
  print(
    'SCENARIO 2: completion wins while reservation is blocked on target ride',
  );

  const driverId = 'driver-city6-completion-race-2';
  const vehicleId = 'vehicle-city6-completion-race-2';
  const shiftId = 'shift-city6-completion-race-2';
  const currentRideId = 'ride-city6-completion-race-2-current';
  const nextRideId = 'ride-city6-completion-race-2-next';
  const reservationId = 'reservation-city6-completion-race-2';

  final startedAt = DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 45));

  final originalPriority = startedAt.add(
    const Duration(minutes: 2),
  );

  final completedAt = DateTime.now().toUtc();

  await _createBusyDriver(
    setupDatabase,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: startedAt,
    queuePrioritySince: originalPriority,
  );

  await _createCurrentRide(
    setupDatabase,
    rideId: currentRideId,
    driverId: driverId,
    vehicleId: vehicleId,
    requestedAt: startedAt.add(const Duration(minutes: 5)),
  );

  await _createWaitingRide(
    setupDatabase,
    rideId: nextRideId,
    requestedAt: startedAt.add(const Duration(minutes: 20)),
  );

  final currentRide = await completionRepository.findById(
    currentRideId,
  );

  if (currentRide == null) {
    throw StateError('Current ride was not found.');
  }

  final completedRide = currentRide
      .copyWith(
        meterFareMinor: 4180,
        commissionRateBps: 1000,
        commissionAmountMinor: 418,
        completedByDriverId: driverId,
        completedAt: completedAt,
      )
      .transitionTo(RideRequestStatus.completed);

  Future<String> reserveNextRide() async {
    try {
      await reservationRepository.reserveWaitingRide(
        reservationId: reservationId,
        rideId: nextRideId,
        driverId: driverId,
        combinedEtaSeconds: 300,
        now: completedAt.subtract(const Duration(seconds: 1)),
      );

      return 'reservationSuccess';
    } on AtomicRideReservationConflictException catch (error) {
      return 'reservationConflict:${error.conflict.name}';
    }
  }

  Future<String> completeCurrentRide() async {
    try {
      await completionRepository.completeRideAndPromoteReservedRide(
        completedRide: completedRide,
      );

      return 'completionSuccess';
    } on AtomicRideCompletionConflictException catch (error) {
      return 'completionConflict:${error.conflict.name}';
    }
  }

  final targetLockReady = Completer<void>();
  final releaseTargetLock = Completer<void>();

  final lockFuture = (setupDatabase as SessionExecutor).runTx(
    (transaction) async {
      final lockResult = await transaction.execute(
        Sql.named('''
          SELECT id
          FROM rides
          WHERE id = @rideId
          FOR UPDATE
        '''),
        parameters: {
          'rideId': nextRideId,
        },
      );

      if (lockResult.length != 1) {
        throw StateError(
          'Could not lock target waiting ride for deterministic race.',
        );
      }

      targetLockReady.complete();

      await releaseTargetLock.future;
    },
  );

  await targetLockReady.future;

  final reservationFuture = reserveNextRide();

  final completionOutcome = await completeCurrentRide();

  releaseTargetLock.complete();
  await lockFuture;

  final reservationOutcome = await reservationFuture;

  if (completionOutcome != 'completionSuccess') {
    throw StateError(
      'Completion did not win deterministic race. '
      'Outcome: $completionOutcome',
    );
  }

  final expectedReservationConflict =
      'reservationConflict:'
      '${AtomicRideReservationConflict.driverNotReservable.name}';

  if (reservationOutcome != expectedReservationConflict) {
    throw StateError(
      'Blocked reservation did not fail with driverNotReservable. '
      'Outcome: $reservationOutcome',
    );
  }

  final currentRideAfter = await _readRide(
    setupDatabase,
    currentRideId,
  );

  if (currentRideAfter['status'] != 'completed' ||
      currentRideAfter['meter_fare_minor'] != 4180 ||
      currentRideAfter['commission_rate_bps'] != 1000 ||
      currentRideAfter['commission_amount_minor'] != 418 ||
      currentRideAfter['completed_by_driver_id'] != driverId ||
      (currentRideAfter['completed_at'] as DateTime?)?.toUtc() !=
          completedAt) {
    throw StateError(
      'Current ride completion data is inconsistent after deterministic race.',
    );
  }

  final nextRideAfter = await _readRide(
    setupDatabase,
    nextRideId,
  );

  if (nextRideAfter['status'] != 'waitingForVehicle' ||
      nextRideAfter['assigned_driver_id'] != null ||
      nextRideAfter['assigned_vehicle_id'] != null) {
    throw StateError(
      'Completion won but next ride did not remain waiting and unassigned.',
    );
  }

  final queueAfter = await _readQueue(
    setupDatabase,
    shiftId,
  );

  if (queueAfter['availability'] != 'available') {
    throw StateError(
      'Completion won but queue did not become available.',
    );
  }

  final priorityAfter =
      (queueAfter['queue_priority_since'] as DateTime).toUtc();

  if (priorityAfter != completedAt) {
    throw StateError(
      'Completion won but queue priority was not reset.',
    );
  }

  final activeReservations = await _countActiveReservationsForDriver(
    setupDatabase,
    driverId,
  );

  if (activeReservations != 0) {
    throw StateError(
      'Completion won but an active reservation remains.',
    );
  }

  final reservationCount = await _countReservationRows(
    setupDatabase,
    reservationId,
  );

  if (reservationCount != 0) {
    throw StateError(
      'Completion won but a reservation row was committed.',
    );
  }

  print('completion won deterministically: OK');
  print('blocked reservation -> driverNotReservable: OK');
  print('next ride remains waiting and unassigned: OK');
  print('queue -> available with priority reset: OK');
  print('no reservation row committed: OK');
}

Future<void> _createBusyDriver(
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
        'City6',
        'CompletionRace',
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
      'queuePrioritySince': queuePrioritySince,
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
        'City6 completion race current pickup',
        'City6 completion race current destination',
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

Future<void> _createWaitingRide(
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
        'City6 completion race next pickup',
        'City6 completion race next destination',
        2,
        TRUE,
        @requestedAt,
        'waitingForVehicle',
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
    throw StateError(
      'Reservation $reservationId was not found.',
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

Future<int> _countReservationRows(
  Session database,
  String reservationId,
) async {
  final result = await database.execute(
    Sql.named('''
      SELECT COUNT(*) AS reservation_count
      FROM ride_reservations
      WHERE id = @reservationId
    '''),
    parameters: {
      'reservationId': reservationId,
    },
  );

  return result.single.toColumnMap()['reservation_count'] as int;
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
    DELETE FROM ride_reservations
    WHERE driver_id LIKE 'driver-city6-completion-race-%'
       OR ride_id LIKE 'ride-city6-completion-race-%'
  ''');

  await database.execute('''
    DELETE FROM ride_offers
    WHERE driver_id LIKE 'driver-city6-completion-race-%'
       OR ride_id LIKE 'ride-city6-completion-race-%'
  ''');

  await database.execute('''
    DELETE FROM rides
    WHERE id LIKE 'ride-city6-completion-race-%'
  ''');

  await database.execute('''
    DELETE FROM driver_queue_states
    WHERE shift_id LIKE 'shift-city6-completion-race-%'
  ''');

  await database.execute('''
    DELETE FROM driver_shifts
    WHERE id LIKE 'shift-city6-completion-race-%'
  ''');

  await database.execute('''
    DELETE FROM vehicles
    WHERE id LIKE 'vehicle-city6-completion-race-%'
  ''');

  await database.execute('''
    DELETE FROM drivers
    WHERE id LIKE 'driver-city6-completion-race-%'
  ''');
}

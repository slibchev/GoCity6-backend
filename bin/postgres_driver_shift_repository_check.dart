import 'dart:io';

import 'package:gocity6_backend/dispatch/postgres_driver_shift_repository.dart';
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
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );

  const driverId = 'driver-shift-check';
  const vehicleId = 'vehicle-shift-check';
  const shiftId = 'shift-repository-check';

  try {
    await _cleanup(connection);

    final createdAt = DateTime.now().toUtc();

    await connection.execute(
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
          @passwordHash,
          @firstName,
          @lastName,
          @phone,
          TRUE,
          @createdAt
        )
      '''),
      parameters: {
        'id': driverId,
        'username': 'driver_shift_repository_check',
        'passwordHash': 'test-only-hash',
        'firstName': 'Test',
        'lastName': 'Shift Driver',
        'phone': 'test-shift-phone',
        'createdAt': createdAt,
      },
    );

    await connection.execute(
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
        'plateNumber': 'TEST-SHIFT-1',
        'createdAt': createdAt,
      },
    );

    final repository = PostgresDriverShiftRepository(database: connection);

    final startedAt = DateTime.now().toUtc().subtract(const Duration(hours: 1));

    var shift = await repository.startShift(
      shiftId: shiftId,
      driverId: driverId,
      vehicleId: vehicleId,
      startedAt: startedAt,
    );

    if (shift.driverId != driverId ||
        shift.vehicleId != vehicleId ||
        shift.queueState.shortBreaksUsed != 0 ||
        shift.queueState.hasPendingOffer) {
      throw StateError('Started shift data does not match.');
    }

    print('startShift: OK');

    var storedShift = await repository.findActiveByDriverId(driverId);

    if (storedShift == null) {
      throw StateError('Active shift was not found.');
    }

    print('findActiveByDriverId: OK');

    final allActive = await repository.findAllActive();

    if (!allActive.any((item) => item.id == shiftId)) {
      throw StateError('Active shift was not returned by findAllActive.');
    }

    print('findAllActive: OK');

    final originalPriority = storedShift.queueState.queuePrioritySince;

    final shortBreakAt = startedAt.add(const Duration(minutes: 5));

    final shortBreakState = storedShift.queueState.startShortBreak(
      shortBreakAt,
    );

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: shortBreakState,
    );

    if (shift.queueState.shortBreaksUsed != 1 ||
        shift.queueState.availability.name != 'shortBreak' ||
        shift.queueState.breakStartedAt == null ||
        shift.queueState.queuePrioritySince != originalPriority) {
      throw StateError('Short break was not persisted correctly.');
    }

    print('short break persistence: OK');

    final autoReturnAt = shortBreakAt.add(const Duration(minutes: 10));

    final autoReturnedState = shift.queueState.effectiveAt(autoReturnAt);

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: autoReturnedState,
    );

    if (shift.queueState.availability.name != 'available' ||
        shift.queueState.breakStartedAt != null ||
        shift.queueState.shortBreaksUsed != 1 ||
        shift.queueState.queuePrioritySince != originalPriority) {
      throw StateError('Automatic short-break return is incorrect.');
    }

    print('short break auto return: OK');

    var offerState = shift.queueState.beginOffer();

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: offerState,
    );

    if (!shift.queueState.hasPendingOffer) {
      throw StateError('Pending offer was not persisted.');
    }

    print('pending offer persistence: OK');

    var endBlocked = false;

    try {
      await repository.endShift(
        shiftId: shiftId,
        endedAt: autoReturnAt.add(const Duration(minutes: 1)),
      );
    } on StateError {
      endBlocked = true;
    }

    if (!endBlocked) {
      throw StateError('Shift end should be blocked while offer is pending.');
    }

    print('end shift with pending offer protection: OK');

    final rejectedAt = autoReturnAt.add(const Duration(minutes: 1));

    final rejectedState = shift.queueState.rejectOffer(rejectedAt);

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: rejectedState,
    );

    if (shift.queueState.hasPendingOffer ||
        shift.queueState.queuePrioritySince != rejectedAt) {
      throw StateError('Reject queue penalty was not persisted.');
    }

    print('reject queue penalty: OK');

    offerState = shift.queueState.beginOffer();

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: offerState,
    );

    final expiredAt = rejectedAt.add(const Duration(seconds: 30));

    final expiredState = shift.queueState.expireOffer(expiredAt);

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: expiredState,
    );

    if (shift.queueState.hasPendingOffer ||
        shift.queueState.queuePrioritySince != expiredAt) {
      throw StateError('Timeout queue penalty was not persisted.');
    }

    print('timeout queue penalty: OK');

    final longBreakAt = expiredAt.add(const Duration(minutes: 1));

    final longBreakState = shift.queueState.startLongBreak(longBreakAt);

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: longBreakState,
    );

    if (shift.queueState.availability.name != 'longBreak' ||
        shift.queueState.breakStartedAt == null ||
        shift.queueState.shortBreaksUsed != 1) {
      throw StateError('Long break was not persisted correctly.');
    }

    print('long break persistence: OK');

    final longBreakReturnAt = longBreakAt.add(const Duration(minutes: 20));

    final returnedFromLongBreak = shift.queueState.returnFromBreak(
      longBreakReturnAt,
    );

    shift = await repository.saveQueueState(
      shiftId: shiftId,
      queueState: returnedFromLongBreak,
    );

    if (shift.queueState.availability.name != 'available' ||
        shift.queueState.breakStartedAt != null ||
        shift.queueState.queuePrioritySince != longBreakReturnAt ||
        shift.queueState.shortBreaksUsed != 1) {
      throw StateError('Long-break return was not persisted correctly.');
    }

    print('long break return to back of queue: OK');

    final directResult = await connection.execute(
      Sql.named('''
        SELECT
          protected_breaks_used
        FROM driver_shifts
        WHERE id = @shiftId
      '''),
      parameters: {'shiftId': shiftId},
    );

    if (directResult.isEmpty || directResult.first[0] != 1) {
      throw StateError('Short-break counter was not stored in driver_shifts.');
    }

    print('short break quota persistence: OK');

    final endedAt = longBreakReturnAt.add(const Duration(minutes: 5));

    await repository.endShift(shiftId: shiftId, endedAt: endedAt);

    final afterEnd = await repository.findActiveByDriverId(driverId);

    if (afterEnd != null) {
      throw StateError('Ended shift is still reported as active.');
    }

    print('endShift: OK');

    final queueRows = await connection.execute(
      Sql.named('''
        SELECT COUNT(*)
        FROM driver_queue_states
        WHERE shift_id = @shiftId
      '''),
      parameters: {'shiftId': shiftId},
    );

    final queueCount = queueRows.first[0] as int;

    if (queueCount != 0) {
      throw StateError('Queue state should be removed after shift end.');
    }

    print('queue cleanup after endShift: OK');

    final endedShiftRows = await connection.execute(
      Sql.named('''
        SELECT
          ended_at,
          protected_breaks_used
        FROM driver_shifts
        WHERE id = @shiftId
      '''),
      parameters: {'shiftId': shiftId},
    );

    if (endedShiftRows.isEmpty ||
        endedShiftRows.first[0] == null ||
        endedShiftRows.first[1] != 1) {
      throw StateError('Ended shift history was not preserved.');
    }

    print('shift history persistence: OK');

    print('');
    print('PostgreSQL driver shift repository check OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _cleanup(Session database) async {
  await database.execute(
    Sql.named('''
      DELETE FROM driver_queue_states
      WHERE shift_id = @shiftId
    '''),
    parameters: {'shiftId': 'shift-repository-check'},
  );

  await database.execute(
    Sql.named('''
      DELETE FROM driver_shifts
      WHERE id = @shiftId
    '''),
    parameters: {'shiftId': 'shift-repository-check'},
  );

  await database.execute(
    Sql.named('''
      DELETE FROM drivers
      WHERE id = @driverId
    '''),
    parameters: {'driverId': 'driver-shift-check'},
  );

  await database.execute(
    Sql.named('''
      DELETE FROM vehicles
      WHERE id = @vehicleId
    '''),
    parameters: {'vehicleId': 'vehicle-shift-check'},
  );
}

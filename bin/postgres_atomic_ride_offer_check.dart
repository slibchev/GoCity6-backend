import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:postgres/postgres.dart';

class _AttemptResult {
  final RideOffer? offer;
  final Object? error;

  const _AttemptResult.success(this.offer) : error = null;

  const _AttemptResult.failure(this.error) : offer = null;

  bool get succeeded => offer != null;
}

Future<void> main() async {
  final password = Platform.environment['CITY6_DB_PASSWORD'];

  if (password == null || password.isEmpty) {
    stderr.writeln('CITY6_DB_PASSWORD is not set.');
    exitCode = 1;
    return;
  }

  final pool = Pool.withEndpoints(
    [
      Endpoint(
        host: 'localhost',
        port: 5432,
        database: 'city6',
        username: 'city6_app',
        password: password,
      ),
    ],
    settings: const PoolSettings(
      sslMode: SslMode.disable,
      maxConnectionCount: 6,
    ),
  );

  try {
    await _cleanup(pool);

    final createdAt = DateTime.now().toUtc();

    await _setupDriver(
      pool,
      driverId: 'driver-atomic-offer-check-1',
      username: 'atomic_offer_check_driver_1',
      vehicleId: 'vehicle-atomic-offer-check-1',
      plateNumber: 'TEST-ATOMIC-1',
      shiftId: 'shift-atomic-offer-check-1',
      createdAt: createdAt,
    );

    await _setupDriver(
      pool,
      driverId: 'driver-atomic-offer-check-2',
      username: 'atomic_offer_check_driver_2',
      vehicleId: 'vehicle-atomic-offer-check-2',
      plateNumber: 'TEST-ATOMIC-2',
      shiftId: 'shift-atomic-offer-check-2',
      createdAt: createdAt,
    );

    await _setupDriver(
      pool,
      driverId: 'driver-atomic-offer-check-3',
      username: 'atomic_offer_check_driver_3',
      vehicleId: 'vehicle-atomic-offer-check-3',
      plateNumber: 'TEST-ATOMIC-3',
      shiftId: 'shift-atomic-offer-check-3',
      createdAt: createdAt,
    );

    print('active shifts setup: OK');

    await _createRide(
      pool,
      rideId: 'ride-atomic-offer-check-1',
      requestedAt: createdAt,
    );

    await _createRide(
      pool,
      rideId: 'ride-atomic-offer-check-2',
      requestedAt: createdAt.add(const Duration(seconds: 1)),
    );

    await _createRide(
      pool,
      rideId: 'ride-atomic-offer-check-3',
      requestedAt: createdAt.add(const Duration(seconds: 2)),
    );

    print('pending rides setup: OK');

    final repository = PostgresAtomicRideOfferRepository(database: pool);

    await _checkTwoRidesOneDriver(pool: pool, repository: repository);

    await _checkOneRideTwoDrivers(pool: pool, repository: repository);

    print('');
    print('PostgreSQL atomic ride offer concurrency check OK');
  } finally {
    await _cleanup(pool);
    await pool.close();
  }
}

Future<void> _checkTwoRidesOneDriver({
  required Pool pool,
  required PostgresAtomicRideOfferRepository repository,
}) async {
  print('');
  print('SCENARIO 1: two rides -> one driver');

  final offeredAt = DateTime.now().toUtc();

  final firstOffer = RideOffer.create(
    id: 'atomic-offer-check-1',
    rideId: 'ride-atomic-offer-check-1',
    driverId: 'driver-atomic-offer-check-1',
    vehicleId: 'vehicle-atomic-offer-check-1',
    etaSeconds: 240,
    distanceMeters: 900,
    offeredAt: offeredAt,
    timeout: const Duration(seconds: 15),
  );

  final secondOffer = RideOffer.create(
    id: 'atomic-offer-check-2',
    rideId: 'ride-atomic-offer-check-2',
    driverId: 'driver-atomic-offer-check-1',
    vehicleId: 'vehicle-atomic-offer-check-1',
    etaSeconds: 300,
    distanceMeters: 1100,
    offeredAt: offeredAt,
    timeout: const Duration(seconds: 15),
  );

  final results = await Future.wait([
    _attemptCreate(repository, firstOffer),
    _attemptCreate(repository, secondOffer),
  ]);

  final successes = results.where((result) => result.succeeded).toList();

  final failures = results.where((result) => !result.succeeded).toList();

  if (successes.length != 1) {
    throw StateError(
      'Scenario 1 expected exactly one success. '
      'Succeeded: ${successes.length}',
    );
  }

  if (failures.length != 1) {
    throw StateError(
      'Scenario 1 expected exactly one failure. '
      'Failed: ${failures.length}',
    );
  }

  print('exactly one concurrent offer succeeded: OK');

  final failure = failures.single.error;

  if (failure is! AtomicRideOfferConflictException) {
    throw StateError('Scenario 1 returned unexpected error: $failure');
  }

  if (failure.conflict !=
      AtomicRideOfferConflict.driverAlreadyHasPendingOffer) {
    throw StateError(
      'Scenario 1 expected '
      'driverAlreadyHasPendingOffer, '
      'got ${failure.conflict.name}.',
    );
  }

  print('second ride blocked by driver pending-offer protection: OK');

  final offerRows = await pool.execute(
    Sql.named('''
      SELECT id
      FROM ride_offers
      WHERE driver_id = @driverId
        AND status = 'pending'
    '''),
    parameters: {'driverId': 'driver-atomic-offer-check-1'},
  );

  if (offerRows.length != 1) {
    throw StateError(
      'Scenario 1 expected one pending offer, '
      'found ${offerRows.length}.',
    );
  }

  print('PostgreSQL contains one pending offer for driver: OK');

  final queueRows = await pool.execute(
    Sql.named('''
      SELECT
        has_pending_offer,
        availability
      FROM driver_queue_states
      WHERE shift_id = @shiftId
    '''),
    parameters: {'shiftId': 'shift-atomic-offer-check-1'},
  );

  if (queueRows.length != 1) {
    throw StateError('Scenario 1 queue state was not found.');
  }

  final queueRow = queueRows.single.toColumnMap();

  if (queueRow['has_pending_offer'] != true ||
      queueRow['availability'] != 'available') {
    throw StateError('Scenario 1 queue state is incorrect.');
  }

  print('driver queue pending-offer state: OK');

  final successfulOffer = successes.single.offer!;

  final failedOfferId = successfulOffer.id == firstOffer.id
      ? secondOffer.id
      : firstOffer.id;

  await _requireOfferDoesNotExist(pool, failedOfferId);

  print('failed transaction rolled back completely: OK');

  print('winning ride: ${successfulOffer.rideId}');
}

Future<void> _checkOneRideTwoDrivers({
  required Pool pool,
  required PostgresAtomicRideOfferRepository repository,
}) async {
  print('');
  print('SCENARIO 2: one ride -> two drivers');

  final offeredAt = DateTime.now().toUtc();

  const rideId = 'ride-atomic-offer-check-3';

  final firstOffer = RideOffer.create(
    id: 'atomic-offer-check-3',
    rideId: rideId,
    driverId: 'driver-atomic-offer-check-2',
    vehicleId: 'vehicle-atomic-offer-check-2',
    etaSeconds: 180,
    distanceMeters: 650,
    offeredAt: offeredAt,
    timeout: const Duration(seconds: 15),
  );

  final secondOffer = RideOffer.create(
    id: 'atomic-offer-check-4',
    rideId: rideId,
    driverId: 'driver-atomic-offer-check-3',
    vehicleId: 'vehicle-atomic-offer-check-3',
    etaSeconds: 210,
    distanceMeters: 750,
    offeredAt: offeredAt,
    timeout: const Duration(seconds: 15),
  );

  final results = await Future.wait([
    _attemptCreate(repository, firstOffer),
    _attemptCreate(repository, secondOffer),
  ]);

  final successes = results.where((result) => result.succeeded).toList();

  final failures = results.where((result) => !result.succeeded).toList();

  if (successes.length != 1) {
    throw StateError(
      'Scenario 2 expected exactly one success. '
      'Succeeded: ${successes.length}',
    );
  }

  if (failures.length != 1) {
    throw StateError(
      'Scenario 2 expected exactly one failure. '
      'Failed: ${failures.length}',
    );
  }

  print('exactly one driver received the ride: OK');

  final failure = failures.single.error;

  if (failure is! AtomicRideOfferConflictException) {
    throw StateError('Scenario 2 returned unexpected error: $failure');
  }

  if (failure.conflict != AtomicRideOfferConflict.rideAlreadyHasPendingOffer) {
    throw StateError(
      'Scenario 2 expected '
      'rideAlreadyHasPendingOffer, '
      'got ${failure.conflict.name}.',
    );
  }

  print('second driver blocked by ride pending-offer protection: OK');

  final pendingRideOffers = await pool.execute(
    Sql.named('''
      SELECT
        id,
        driver_id
      FROM ride_offers
      WHERE ride_id = @rideId
        AND status = 'pending'
    '''),
    parameters: {'rideId': rideId},
  );

  if (pendingRideOffers.length != 1) {
    throw StateError(
      'Scenario 2 expected exactly one pending offer '
      'for the ride, found ${pendingRideOffers.length}.',
    );
  }

  print('PostgreSQL contains one pending offer for ride: OK');

  final successfulOffer = successes.single.offer!;

  final winningShiftId =
      successfulOffer.driverId == 'driver-atomic-offer-check-2'
      ? 'shift-atomic-offer-check-2'
      : 'shift-atomic-offer-check-3';

  final losingShiftId =
      successfulOffer.driverId == 'driver-atomic-offer-check-2'
      ? 'shift-atomic-offer-check-3'
      : 'shift-atomic-offer-check-2';

  final winningQueue = await _readPendingOfferFlag(pool, winningShiftId);

  final losingQueue = await _readPendingOfferFlag(pool, losingShiftId);

  if (!winningQueue) {
    throw StateError(
      'Scenario 2 winning driver must have '
      'has_pending_offer = TRUE.',
    );
  }

  if (losingQueue) {
    throw StateError(
      'Scenario 2 losing driver must remain '
      'has_pending_offer = FALSE.',
    );
  }

  print('winning driver marked with pending offer: OK');
  print('losing driver remained available: OK');

  final failedOfferId = successfulOffer.id == firstOffer.id
      ? secondOffer.id
      : firstOffer.id;

  await _requireOfferDoesNotExist(pool, failedOfferId);

  print('failed transaction rolled back completely: OK');

  print('winning driver: ${successfulOffer.driverId}');
}

Future<_AttemptResult> _attemptCreate(
  PostgresAtomicRideOfferRepository repository,
  RideOffer offer,
) async {
  try {
    final created = await repository.createPendingOffer(offer: offer);

    return _AttemptResult.success(created);
  } catch (error) {
    return _AttemptResult.failure(error);
  }
}

Future<void> _setupDriver(
  Session database, {
  required String driverId,
  required String username,
  required String vehicleId,
  required String plateNumber,
  required String shiftId,
  required DateTime createdAt,
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
      'username': username,
      'passwordHash': 'test-only-hash',
      'firstName': 'Atomic',
      'lastName': 'Offer Driver',
      'phone': 'test-$driverId',
      'createdAt': createdAt,
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
      'plateNumber': plateNumber,
      'createdAt': createdAt,
    },
  );

  final repository = PostgresDriverShiftRepository(
    database: database as SessionExecutor,
  );

  await repository.startShift(
    shiftId: shiftId,
    driverId: driverId,
    vehicleId: vehicleId,
    startedAt: createdAt,
  );
}

Future<void> _createRide(
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
        currency
      )
      VALUES (
        @id,
        @pickup,
        @destination,
        1,
        FALSE,
        @requestedAt,
        'pending',
        'EUR'
      )
    '''),
    parameters: {
      'id': rideId,
      'pickup': 'Atomic offer pickup',
      'destination': 'Atomic offer destination',
      'requestedAt': requestedAt.toUtc(),
    },
  );
}

Future<bool> _readPendingOfferFlag(Session database, String shiftId) async {
  final result = await database.execute(
    Sql.named('''
      SELECT has_pending_offer
      FROM driver_queue_states
      WHERE shift_id = @shiftId
    '''),
    parameters: {'shiftId': shiftId},
  );

  if (result.length != 1) {
    throw StateError('Queue state not found for $shiftId.');
  }

  return result.single[0] as bool;
}

Future<void> _requireOfferDoesNotExist(Session database, String offerId) async {
  final result = await database.execute(
    Sql.named('''
      SELECT COUNT(*)
      FROM ride_offers
      WHERE id = @offerId
    '''),
    parameters: {'offerId': offerId},
  );

  final count = result.first[0] as int;

  if (count != 0) {
    throw StateError('Failed offer $offerId was persisted.');
  }
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
      DELETE FROM ride_offers
      WHERE ride_id IN (
        'ride-atomic-offer-check-1',
        'ride-atomic-offer-check-2',
        'ride-atomic-offer-check-3'
      )
    ''');

  await database.execute('''
      DELETE FROM driver_queue_states
      WHERE shift_id IN (
        'shift-atomic-offer-check-1',
        'shift-atomic-offer-check-2',
        'shift-atomic-offer-check-3'
      )
    ''');

  await database.execute('''
      DELETE FROM driver_shifts
      WHERE id IN (
        'shift-atomic-offer-check-1',
        'shift-atomic-offer-check-2',
        'shift-atomic-offer-check-3'
      )
    ''');

  await database.execute('''
      DELETE FROM rides
      WHERE id IN (
        'ride-atomic-offer-check-1',
        'ride-atomic-offer-check-2',
        'ride-atomic-offer-check-3'
      )
    ''');

  await database.execute('''
      DELETE FROM drivers
      WHERE id IN (
        'driver-atomic-offer-check-1',
        'driver-atomic-offer-check-2',
        'driver-atomic-offer-check-3'
      )
    ''');

  await database.execute('''
      DELETE FROM vehicles
      WHERE id IN (
        'vehicle-atomic-offer-check-1',
        'vehicle-atomic-offer-check-2',
        'vehicle-atomic-offer-check-3'
      )
    ''');
}

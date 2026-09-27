import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:postgres/postgres.dart';

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
      maxConnectionCount: 4,
    ),
  );

  try {
    await _cleanup(pool);

    final repository = PostgresAtomicRideOfferRepository(database: pool);

    await _checkNoOfferFallback(pool, repository);

    await _checkPendingOfferBlocksFallback(pool, repository);

    await _checkAcceptedRideBlocksFallback(pool, repository);

    print('');
    print('PostgreSQL waiting-for-vehicle fallback check OK');
  } finally {
    await _cleanup(pool);
    await pool.close();
  }
}

Future<void> _checkNoOfferFallback(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 1: pending ride with no offer');

  const rideId = 'ride-fallback-no-offer';

  final now = DateTime.now().toUtc();

  await _createPendingRide(pool, rideId: rideId, requestedAt: now);

  await repository.movePendingRideToWaitingForVehicle(rideId: rideId);

  final ride = await _readRide(pool, rideId);

  if (ride['status'] != 'waitingForVehicle') {
    throw StateError('Ride should be waitingForVehicle.');
  }

  if (ride['assigned_driver_id'] != null ||
      ride['assigned_vehicle_id'] != null) {
    throw StateError('Waiting ride must remain unassigned.');
  }

  print('pending -> waitingForVehicle: OK');
  print('ride remains unassigned: OK');
}

Future<void> _checkPendingOfferBlocksFallback(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 2: pending offer blocks fallback');

  const suffix = 'pending-offer';

  final now = DateTime.now().toUtc();

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: suffix,
    offeredAt: now,
  );

  await _expectConflict(
    () => repository.movePendingRideToWaitingForVehicle(rideId: offer.rideId),
    AtomicRideOfferConflict.rideHasPendingOffer,
  );

  final ride = await _readRide(pool, offer.rideId);

  if (ride['status'] != 'pending') {
    throw StateError('Ride changed while active offer existed.');
  }

  final offerRow = await _readOffer(pool, offer.id);

  if (offerRow['status'] != 'pending') {
    throw StateError('Active offer changed during failed fallback.');
  }

  print('fallback blocked while offer is pending: OK');
  print('ride remained pending: OK');
  print('offer remained pending: OK');
}

Future<void> _checkAcceptedRideBlocksFallback(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 3: accepted ride blocks fallback');

  const suffix = 'accepted';

  final offeredAt = DateTime.now().toUtc();

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: suffix,
    offeredAt: offeredAt,
  );

  final acceptedAt = offeredAt.add(const Duration(seconds: 5));

  await repository.acceptPendingOffer(offerId: offer.id, now: acceptedAt);

  await _expectConflict(
    () => repository.movePendingRideToWaitingForVehicle(rideId: offer.rideId),
    AtomicRideOfferConflict.rideNotPending,
  );

  final ride = await _readRide(pool, offer.rideId);

  if (ride['status'] != 'accepted') {
    throw StateError('Accepted ride status changed during failed fallback.');
  }

  if (ride['assigned_driver_id'] != offer.driverId ||
      ride['assigned_vehicle_id'] != offer.vehicleId) {
    throw StateError('Accepted ride assignment changed.');
  }

  print('fallback blocked for accepted ride: OK');
  print('accepted status preserved: OK');
  print('driver and vehicle assignment preserved: OK');
}

Future<RideOffer> _setupPendingOffer(
  Pool pool,
  PostgresAtomicRideOfferRepository repository, {
  required String suffix,
  required DateTime offeredAt,
}) async {
  final driverId = 'driver-fallback-$suffix';
  final vehicleId = 'vehicle-fallback-$suffix';
  final shiftId = 'shift-fallback-$suffix';
  final rideId = 'ride-fallback-$suffix';
  final offerId = 'offer-fallback-$suffix';

  final createdAt = offeredAt.subtract(const Duration(minutes: 5));

  await pool.execute(
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
        'Fallback',
        'Driver',
        @phone,
        TRUE,
        @createdAt
      )
    '''),
    parameters: {
      'id': driverId,
      'username': 'fallback_$suffix',
      'passwordHash': 'test-only-hash',
      'phone': 'test-$suffix',
      'createdAt': createdAt,
    },
  );

  await pool.execute(
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
      'plateNumber': 'FB-$suffix',
      'createdAt': createdAt,
    },
  );

  final shiftRepository = PostgresDriverShiftRepository(database: pool);

  await shiftRepository.startShift(
    shiftId: shiftId,
    driverId: driverId,
    vehicleId: vehicleId,
    startedAt: createdAt,
  );

  await _createPendingRide(pool, rideId: rideId, requestedAt: createdAt);

  final offer = RideOffer.create(
    id: offerId,
    rideId: rideId,
    driverId: driverId,
    vehicleId: vehicleId,
    etaSeconds: 240,
    distanceMeters: 900,
    offeredAt: offeredAt,
    timeout: const Duration(seconds: 15),
  );

  await repository.createPendingOffer(offer: offer);

  return offer;
}

Future<void> _createPendingRide(
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
        'Fallback pickup',
        'Fallback destination',
        1,
        FALSE,
        @requestedAt,
        'pending',
        'EUR'
      )
    '''),
    parameters: {'id': rideId, 'requestedAt': requestedAt.toUtc()},
  );
}

Future<void> _expectConflict(
  Future<void> Function() operation,
  AtomicRideOfferConflict expected,
) async {
  try {
    await operation();
  } on AtomicRideOfferConflictException catch (error) {
    if (error.conflict != expected) {
      throw StateError(
        'Expected ${expected.name}, '
        'got ${error.conflict.name}.',
      );
    }

    return;
  }

  throw StateError('Expected conflict ${expected.name}.');
}

Future<Map<String, dynamic>> _readRide(Session database, String rideId) async {
  final result = await database.execute(
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

  if (result.length != 1) {
    throw StateError('Ride $rideId was not found.');
  }

  return result.single.toColumnMap();
}

Future<Map<String, dynamic>> _readOffer(
  Session database,
  String offerId,
) async {
  final result = await database.execute(
    Sql.named('''
      SELECT
        status,
        resolved_at
      FROM ride_offers
      WHERE id = @offerId
    '''),
    parameters: {'offerId': offerId},
  );

  if (result.length != 1) {
    throw StateError('Offer $offerId was not found.');
  }

  return result.single.toColumnMap();
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
      DELETE FROM ride_offers
      WHERE id LIKE 'offer-fallback-%'
    ''');

  await database.execute('''
      DELETE FROM driver_queue_states
      WHERE shift_id LIKE 'shift-fallback-%'
    ''');

  await database.execute('''
      DELETE FROM driver_shifts
      WHERE id LIKE 'shift-fallback-%'
    ''');

  await database.execute('''
      DELETE FROM rides
      WHERE id LIKE 'ride-fallback-%'
    ''');

  await database.execute('''
      DELETE FROM drivers
      WHERE id LIKE 'driver-fallback-%'
    ''');

  await database.execute('''
      DELETE FROM vehicles
      WHERE id LIKE 'vehicle-fallback-%'
    ''');
}

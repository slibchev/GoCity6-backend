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

    await _checkAccept(pool, repository);
    await _checkReject(pool, repository);
    await _checkExpire(pool, repository);
    await _checkAcceptAfterDeadline(pool, repository);
    await _checkRejectAfterDeadline(pool, repository);
    await _checkExpireBeforeDeadline(pool, repository);
    await _checkDoubleResolution(pool, repository);

    print('');
    print('PostgreSQL atomic ride offer resolution check OK');
  } finally {
    await _cleanup(pool);
    await pool.close();
  }
}

Future<void> _checkAccept(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 1: accept');

  final now = DateTime.now().toUtc();

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: 'accept',
    offeredAt: now,
  );

  final acceptedAt = now.add(const Duration(seconds: 5));

  final accepted = await repository.acceptPendingOffer(
    offerId: offer.id,
    now: acceptedAt,
  );

  if (accepted.status != RideOfferStatus.accepted ||
      accepted.resolvedAt != acceptedAt) {
    throw StateError('Accepted offer result is incorrect.');
  }

  final offerRow = await _readOffer(pool, offer.id);

  if (offerRow['status'] != 'accepted' || offerRow['resolved_at'] == null) {
    throw StateError('Accepted offer was not persisted.');
  }

  final rideRow = await _readRide(pool, offer.rideId);

  if (rideRow['status'] != 'accepted' ||
      rideRow['assigned_driver_id'] != offer.driverId ||
      rideRow['assigned_vehicle_id'] != offer.vehicleId) {
    throw StateError('Ride assignment was not persisted atomically.');
  }

  final queueRow = await _readQueueByDriver(pool, offer.driverId);

  if (queueRow['availability'] != 'busy' ||
      queueRow['has_pending_offer'] != false) {
    throw StateError('Driver queue state after accept is incorrect.');
  }

  print('offer pending -> accepted: OK');
  print('ride pending -> accepted + assignment: OK');
  print('driver available -> busy: OK');
  print('has_pending_offer -> FALSE: OK');
}

Future<void> _checkReject(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 2: reject');

  final now = DateTime.now().toUtc();

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: 'reject',
    offeredAt: now,
  );

  final rejectedAt = now.add(const Duration(seconds: 5));

  final rejected = await repository.rejectPendingOffer(
    offerId: offer.id,
    now: rejectedAt,
  );

  if (rejected.status != RideOfferStatus.rejected ||
      rejected.resolvedAt != rejectedAt) {
    throw StateError('Rejected offer result is incorrect.');
  }

  final offerRow = await _readOffer(pool, offer.id);

  if (offerRow['status'] != 'rejected' || offerRow['resolved_at'] == null) {
    throw StateError('Rejected offer was not persisted.');
  }

  final rideRow = await _readRide(pool, offer.rideId);

  if (rideRow['status'] != 'pending' ||
      rideRow['assigned_driver_id'] != null ||
      rideRow['assigned_vehicle_id'] != null) {
    throw StateError('Rejected ride must remain unassigned and pending.');
  }

  final queueRow = await _readQueueByDriver(pool, offer.driverId);

  if (queueRow['availability'] != 'available' ||
      queueRow['has_pending_offer'] != false) {
    throw StateError('Driver queue state after reject is incorrect.');
  }

  final queuePrioritySince = (queueRow['queue_priority_since'] as DateTime)
      .toUtc();

  if (queuePrioritySince != rejectedAt) {
    throw StateError('Reject did not move driver to the back of the queue.');
  }

  print('offer pending -> rejected: OK');
  print('ride remains pending and unassigned: OK');
  print('has_pending_offer -> FALSE: OK');
  print('queue_priority_since -> reject time: OK');
}

Future<void> _checkExpire(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 3: timeout / expire');

  final offeredAt = DateTime.now().toUtc().subtract(
    const Duration(seconds: 30),
  );

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: 'expire',
    offeredAt: offeredAt,
  );

  final expiredAt = offeredAt.add(const Duration(seconds: 20));

  final expired = await repository.expirePendingOffer(
    offerId: offer.id,
    now: expiredAt,
  );

  if (expired.status != RideOfferStatus.expired ||
      expired.resolvedAt != expiredAt) {
    throw StateError('Expired offer result is incorrect.');
  }

  final offerRow = await _readOffer(pool, offer.id);

  if (offerRow['status'] != 'expired' || offerRow['resolved_at'] == null) {
    throw StateError('Expired offer was not persisted.');
  }

  final rideRow = await _readRide(pool, offer.rideId);

  if (rideRow['status'] != 'pending' ||
      rideRow['assigned_driver_id'] != null ||
      rideRow['assigned_vehicle_id'] != null) {
    throw StateError('Expired ride must remain unassigned and pending.');
  }

  final queueRow = await _readQueueByDriver(pool, offer.driverId);

  final queuePrioritySince = (queueRow['queue_priority_since'] as DateTime)
      .toUtc();

  if (queueRow['availability'] != 'available' ||
      queueRow['has_pending_offer'] != false ||
      queuePrioritySince != expiredAt) {
    throw StateError('Timeout queue penalty was not persisted correctly.');
  }

  print('offer pending -> expired: OK');
  print('ride remains pending and unassigned: OK');
  print('timeout clears pending offer: OK');
  print('timeout moves driver to back of queue: OK');
}

Future<void> _checkAcceptAfterDeadline(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 4: accept after deadline');

  final offeredAt = DateTime.now().toUtc().subtract(
    const Duration(seconds: 30),
  );

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: 'late-accept',
    offeredAt: offeredAt,
  );

  final now = offeredAt.add(const Duration(seconds: 20));

  await _expectConflict(
    () => repository.acceptPendingOffer(offerId: offer.id, now: now),
    AtomicRideOfferConflict.offerAlreadyExpired,
  );

  await _requireStillPending(pool, offer);

  print('late accept blocked: OK');
  print('failed transaction left offer pending: OK');
}

Future<void> _checkRejectAfterDeadline(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 5: reject after deadline');

  final offeredAt = DateTime.now().toUtc().subtract(
    const Duration(seconds: 30),
  );

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: 'late-reject',
    offeredAt: offeredAt,
  );

  final now = offeredAt.add(const Duration(seconds: 20));

  await _expectConflict(
    () => repository.rejectPendingOffer(offerId: offer.id, now: now),
    AtomicRideOfferConflict.offerAlreadyExpired,
  );

  await _requireStillPending(pool, offer);

  print('late reject blocked: OK');
  print('failed transaction left offer pending: OK');
}

Future<void> _checkExpireBeforeDeadline(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 6: expire before deadline');

  final offeredAt = DateTime.now().toUtc();

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: 'early-expire',
    offeredAt: offeredAt,
  );

  final now = offeredAt.add(const Duration(seconds: 5));

  await _expectConflict(
    () => repository.expirePendingOffer(offerId: offer.id, now: now),
    AtomicRideOfferConflict.offerNotExpiredYet,
  );

  await _requireStillPending(pool, offer);

  print('early expire blocked: OK');
  print('failed transaction left offer pending: OK');
}

Future<void> _checkDoubleResolution(
  Pool pool,
  PostgresAtomicRideOfferRepository repository,
) async {
  print('');
  print('SCENARIO 7: double resolution');

  final offeredAt = DateTime.now().toUtc();

  final offer = await _setupPendingOffer(
    pool,
    repository,
    suffix: 'double',
    offeredAt: offeredAt,
  );

  final rejectedAt = offeredAt.add(const Duration(seconds: 5));

  await repository.rejectPendingOffer(offerId: offer.id, now: rejectedAt);

  await _expectConflict(
    () => repository.rejectPendingOffer(
      offerId: offer.id,
      now: rejectedAt.add(const Duration(seconds: 1)),
    ),
    AtomicRideOfferConflict.offerNotPending,
  );

  final offerRow = await _readOffer(pool, offer.id);

  if (offerRow['status'] != 'rejected') {
    throw StateError('Double resolution changed resolved offer.');
  }

  print('first resolution succeeded: OK');
  print('second resolution blocked: OK');
  print('resolved state remained unchanged: OK');
}

Future<RideOffer> _setupPendingOffer(
  Pool pool,
  PostgresAtomicRideOfferRepository repository, {
  required String suffix,
  required DateTime offeredAt,
}) async {
  final driverId = 'driver-resolution-$suffix';
  final vehicleId = 'vehicle-resolution-$suffix';
  final shiftId = 'shift-resolution-$suffix';
  final rideId = 'ride-resolution-$suffix';
  final offerId = 'offer-resolution-$suffix';

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
        'Atomic',
        'Resolution Driver',
        @phone,
        TRUE,
        @createdAt
      )
    '''),
    parameters: {
      'id': driverId,
      'username': 'resolution_$suffix',
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
      'plateNumber': 'RES-$suffix',
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

  await pool.execute(
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
        'Resolution pickup',
        'Resolution destination',
        1,
        FALSE,
        @requestedAt,
        'pending',
        'EUR'
      )
    '''),
    parameters: {'id': rideId, 'requestedAt': createdAt},
  );

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

  await repository.createPendingOffer(offer: offer, maxAttempts: 3);

  return offer;
}

Future<void> _expectConflict(
  Future<RideOffer> Function() operation,
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

Future<void> _requireStillPending(Pool pool, RideOffer offer) async {
  final offerRow = await _readOffer(pool, offer.id);

  if (offerRow['status'] != 'pending' || offerRow['resolved_at'] != null) {
    throw StateError('Offer should still be pending.');
  }

  final rideRow = await _readRide(pool, offer.rideId);

  if (rideRow['status'] != 'pending' ||
      rideRow['assigned_driver_id'] != null ||
      rideRow['assigned_vehicle_id'] != null) {
    throw StateError('Ride changed during failed resolution.');
  }

  final queueRow = await _readQueueByDriver(pool, offer.driverId);

  if (queueRow['availability'] != 'available' ||
      queueRow['has_pending_offer'] != true) {
    throw StateError('Queue state changed during failed resolution.');
  }
}

Future<Map<String, dynamic>> _readOffer(Pool pool, String offerId) async {
  final result = await pool.execute(
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

Future<Map<String, dynamic>> _readRide(Pool pool, String rideId) async {
  final result = await pool.execute(
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

Future<Map<String, dynamic>> _readQueueByDriver(
  Pool pool,
  String driverId,
) async {
  final result = await pool.execute(
    Sql.named('''
      SELECT
        q.availability,
        q.has_pending_offer,
        q.queue_priority_since
      FROM driver_shifts s
      JOIN driver_queue_states q
        ON q.shift_id = s.id
      WHERE s.driver_id = @driverId
        AND s.ended_at IS NULL
    '''),
    parameters: {'driverId': driverId},
  );

  if (result.length != 1) {
    throw StateError('Queue state for $driverId was not found.');
  }

  return result.single.toColumnMap();
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
      DELETE FROM ride_offers
      WHERE id LIKE 'offer-resolution-%'
    ''');

  await database.execute('''
      DELETE FROM driver_queue_states
      WHERE shift_id LIKE 'shift-resolution-%'
    ''');

  await database.execute('''
      DELETE FROM driver_shifts
      WHERE id LIKE 'shift-resolution-%'
    ''');

  await database.execute('''
      DELETE FROM rides
      WHERE id LIKE 'ride-resolution-%'
    ''');

  await database.execute('''
      DELETE FROM drivers
      WHERE id LIKE 'driver-resolution-%'
    ''');

  await database.execute('''
      DELETE FROM vehicles
      WHERE id LIKE 'vehicle-resolution-%'
    ''');
}

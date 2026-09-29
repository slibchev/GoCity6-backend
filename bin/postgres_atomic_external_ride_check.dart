import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_external_ride_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_external_ride_repository.dart';
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

  final repository = PostgresAtomicExternalRideRepository(database: connection);

  try {
    await _cleanup(connection);

    await _checkStartWithoutOffer(connection, repository);

    await _checkStartWithValidPendingOffer(connection, repository);

    await _checkStartWithExpiredPendingOffer(connection, repository);

    print('');
    print('PostgreSQL atomic external ride check OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _checkStartWithoutOffer(
  Session database,
  PostgresAtomicExternalRideRepository repository,
) async {
  print('');
  print('SCENARIO 1: available driver -> Zает without offer');

  const driverId = 'driver-atomic-external-1';
  const vehicleId = 'vehicle-atomic-external-1';
  const shiftId = 'shift-atomic-external-1';
  const sessionId = 'external-session-atomic-1';

  final startedAt = DateTime.now().toUtc().subtract(
    const Duration(minutes: 20),
  );

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: startedAt,
    hasPendingOffer: false,
  );

  final beforeQueue = await _readQueueState(database, shiftId);

  final originalPriority = (beforeQueue['queue_priority_since'] as DateTime)
      .toUtc();

  final now = DateTime.now().toUtc();

  final result = await repository.startExternalRide(
    sessionId: sessionId,
    driverId: driverId,
    now: now,
  );

  if (result.offerResolution != AtomicExternalRideStartOfferResolution.none) {
    throw StateError('Expected no offer resolution.');
  }

  if (result.resolvedOfferId != null || result.resolvedRideId != null) {
    throw StateError('Unexpected resolved offer data.');
  }

  if (result.session.triggerOfferId != null ||
      result.session.triggerRideId != null) {
    throw StateError('Session unexpectedly has trigger offer.');
  }

  final queue = await _readQueueState(database, shiftId);

  if (queue['availability'] != 'externalRide' ||
      queue['has_pending_offer'] != false) {
    throw StateError('Queue state was not changed to externalRide correctly.');
  }

  final priorityAfter = (queue['queue_priority_since'] as DateTime).toUtc();

  if (priorityAfter != originalPriority) {
    throw StateError('Starting external ride changed queue priority.');
  }

  print('availability -> externalRide: OK');
  print('has_pending_offer remains false: OK');
  print('session has no trigger: OK');
  print('queue priority preserved while becoming busy: OK');
}

Future<void> _checkStartWithValidPendingOffer(
  Session database,
  PostgresAtomicExternalRideRepository repository,
) async {
  print('');
  print('SCENARIO 2: valid pending offer -> Zает');

  const driverId = 'driver-atomic-external-2';
  const vehicleId = 'vehicle-atomic-external-2';
  const shiftId = 'shift-atomic-external-2';
  const rideId = 'ride-atomic-external-2';
  const offerId = 'offer-atomic-external-2';
  const sessionId = 'external-session-atomic-2';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(const Duration(minutes: 20)),
    hasPendingOffer: true,
  );

  await _createPendingRide(database, rideId: rideId);

  await _createPendingOffer(
    database,
    offerId: offerId,
    rideId: rideId,
    driverId: driverId,
    vehicleId: vehicleId,
    offeredAt: now.subtract(const Duration(seconds: 5)),
    expiresAt: now.add(const Duration(seconds: 10)),
  );

  final result = await repository.startExternalRide(
    sessionId: sessionId,
    driverId: driverId,
    now: now,
  );

  if (result.offerResolution !=
      AtomicExternalRideStartOfferResolution.becameBusy) {
    throw StateError('Expected becameBusy resolution.');
  }

  if (result.resolvedOfferId != offerId || result.resolvedRideId != rideId) {
    throw StateError('Resolved offer identifiers do not match.');
  }

  if (result.session.triggerOfferId != offerId ||
      result.session.triggerRideId != rideId) {
    throw StateError('External ride session did not preserve trigger offer.');
  }

  final offer = await _readOffer(database, offerId);

  if (offer['status'] != 'rejected' || offer['resolved_at'] == null) {
    throw StateError('Valid pending offer was not resolved as rejected.');
  }

  final queue = await _readQueueState(database, shiftId);

  if (queue['availability'] != 'externalRide' ||
      queue['has_pending_offer'] != false) {
    throw StateError('Queue state is incorrect after becameBusy.');
  }

  print('pending offer -> rejected: OK');
  print('offer resolution -> becameBusy: OK');
  print('trigger offer/ride stored in session: OK');
  print('availability -> externalRide: OK');
  print('has_pending_offer -> false: OK');
}

Future<void> _checkStartWithExpiredPendingOffer(
  Session database,
  PostgresAtomicExternalRideRepository repository,
) async {
  print('');
  print('SCENARIO 3: already expired pending offer -> Zает');

  const driverId = 'driver-atomic-external-3';
  const vehicleId = 'vehicle-atomic-external-3';
  const shiftId = 'shift-atomic-external-3';
  const rideId = 'ride-atomic-external-3';
  const offerId = 'offer-atomic-external-3';
  const sessionId = 'external-session-atomic-3';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(const Duration(minutes: 20)),
    hasPendingOffer: true,
  );

  await _createPendingRide(database, rideId: rideId);

  await _createPendingOffer(
    database,
    offerId: offerId,
    rideId: rideId,
    driverId: driverId,
    vehicleId: vehicleId,
    offeredAt: now.subtract(const Duration(seconds: 30)),
    expiresAt: now.subtract(const Duration(seconds: 15)),
  );

  final result = await repository.startExternalRide(
    sessionId: sessionId,
    driverId: driverId,
    now: now,
  );

  if (result.offerResolution !=
      AtomicExternalRideStartOfferResolution.expired) {
    throw StateError('Expected expired offer resolution.');
  }

  if (result.resolvedOfferId != offerId || result.resolvedRideId != rideId) {
    throw StateError('Expired offer identifiers do not match.');
  }

  if (result.session.triggerOfferId != null ||
      result.session.triggerRideId != null) {
    throw StateError('Expired offer must not trigger 500 meter exception.');
  }

  final offer = await _readOffer(database, offerId);

  if (offer['status'] != 'expired' || offer['resolved_at'] == null) {
    throw StateError('Expired offer was not resolved correctly.');
  }

  final queue = await _readQueueState(database, shiftId);

  if (queue['availability'] != 'externalRide' ||
      queue['has_pending_offer'] != false) {
    throw StateError('Queue state is incorrect after expired offer.');
  }

  print('pending-but-expired offer -> expired: OK');
  print('offer resolution -> expired: OK');
  print('expired offer is NOT session trigger: OK');
  print('availability -> externalRide: OK');
  print('has_pending_offer -> false: OK');
}

Future<void> _createDriverVehicleAndShift(
  Session database, {
  required String driverId,
  required String vehicleId,
  required String shiftId,
  required DateTime startedAt,
  required bool hasPendingOffer,
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
        'External',
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
        @hasPendingOffer
      )
    '''),
    parameters: {
      'shiftId': shiftId,
      'queuePrioritySince': startedAt,
      'hasPendingOffer': hasPendingOffer,
    },
  );
}

Future<void> _createPendingRide(
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
        'Atomic external pickup',
        'Atomic external destination',
        1,
        FALSE,
        @requestedAt,
        'pending',
        1,
        0,
        'not_offered',
        'EUR'
      )
    '''),
    parameters: {'id': rideId, 'requestedAt': DateTime.now().toUtc()},
  );
}

Future<void> _createPendingOffer(
  Session database, {
  required String offerId,
  required String rideId,
  required String driverId,
  required String vehicleId,
  required DateTime offeredAt,
  required DateTime expiresAt,
}) async {
  await database.execute(
    Sql.named('''
      INSERT INTO ride_offers (
        id,
        ride_id,
        driver_id,
        vehicle_id,
        eta_seconds,
        distance_meters,
        dispatch_round,
        bonus_minor,
        offered_at,
        expires_at,
        status,
        resolved_at
      )
      VALUES (
        @id,
        @rideId,
        @driverId,
        @vehicleId,
        240,
        900,
        1,
        0,
        @offeredAt,
        @expiresAt,
        'pending',
        NULL
      )
    '''),
    parameters: {
      'id': offerId,
      'rideId': rideId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'offeredAt': offeredAt,
      'expiresAt': expiresAt,
    },
  );
}

Future<Map<String, dynamic>> _readQueueState(
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
    parameters: {'shiftId': shiftId},
  );

  if (result.length != 1) {
    throw StateError('Queue state $shiftId was not found.');
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
      DELETE FROM external_ride_sessions
      WHERE driver_id LIKE 'driver-atomic-external-%'
    ''');

  await database.execute('''
      DELETE FROM ride_offers
      WHERE driver_id LIKE 'driver-atomic-external-%'
    ''');

  await database.execute('''
      DELETE FROM rides
      WHERE id LIKE 'ride-atomic-external-%'
    ''');

  await database.execute('''
      DELETE FROM driver_queue_states
      WHERE shift_id LIKE 'shift-atomic-external-%'
    ''');

  await database.execute('''
      DELETE FROM driver_shifts
      WHERE id LIKE 'shift-atomic-external-%'
    ''');

  await database.execute('''
      DELETE FROM vehicles
      WHERE id LIKE 'vehicle-atomic-external-%'
    ''');

  await database.execute('''
      DELETE FROM drivers
      WHERE id LIKE 'driver-atomic-external-%'
    ''');
}

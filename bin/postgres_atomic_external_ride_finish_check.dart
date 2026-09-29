import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_external_ride_repository.dart';
import 'package:gocity6_backend/dispatch/external_ride_session.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_external_ride_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_external_ride_session_repository.dart';
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

  final atomicRepository = PostgresAtomicExternalRideRepository(
    database: connection,
  );

  final sessionRepository = PostgresExternalRideSessionRepository(
    database: connection,
  );

  try {
    await _cleanup(connection);

    await _check499MetersCountsAsRejection(
      connection,
      atomicRepository,
      sessionRepository,
    );

    await _check500MetersDoesNotCountAsRejection(
      connection,
      atomicRepository,
      sessionRepository,
    );

    await _checkNoTriggerNeverCountsAsRejection(
      connection,
      atomicRepository,
      sessionRepository,
    );

    print('');
    print('PostgreSQL atomic external ride finish check OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _check499MetersCountsAsRejection(
  Session database,
  PostgresAtomicExternalRideRepository atomicRepository,
  PostgresExternalRideSessionRepository sessionRepository,
) async {
  print('');
  print('SCENARIO 1: triggered external ride ends at 499 m');

  const suffix = '499';

  final data = await _preparePendingOfferScenario(database, suffix: suffix);

  final startResult = await atomicRepository.startExternalRide(
    sessionId: 'external-finish-$suffix',
    driverId: data.driverId,
    now: data.now,
  );

  if (startResult.offerResolution !=
      AtomicExternalRideStartOfferResolution.becameBusy) {
    throw StateError('Expected becameBusy start resolution.');
  }

  await sessionRepository.addVerifiedDistance(
    driverId: data.driverId,
    segmentDistanceMeters: 499,
  );

  final finishedAt = data.now.add(const Duration(minutes: 10));

  final result = await atomicRepository.finishExternalRide(
    driverId: data.driverId,
    now: finishedAt,
  );

  if (result.session.distanceMeters != 499) {
    throw StateError('Expected 499 meters.');
  }

  if (!result.shouldCountTriggeredOfferAsRejection) {
    throw StateError('499 meters must count the triggered offer as rejection.');
  }

  if (result.triggerOfferId != data.offerId ||
      result.triggerRideId != data.rideId) {
    throw StateError('Trigger offer data was not preserved.');
  }

  await _assertReturnedToAvailableBackOfQueue(
    database,
    shiftId: data.shiftId,
    expectedPriority: finishedAt,
  );

  print('distance = 499 m: OK');
  print('triggered offer counts as rejection: OK');
  print('driver -> available: OK');
  print('queuePrioritySince -> finish time: OK');
}

Future<void> _check500MetersDoesNotCountAsRejection(
  Session database,
  PostgresAtomicExternalRideRepository atomicRepository,
  PostgresExternalRideSessionRepository sessionRepository,
) async {
  print('');
  print('SCENARIO 2: triggered external ride reaches exactly 500 m');

  const suffix = '500';

  final data = await _preparePendingOfferScenario(database, suffix: suffix);

  final startResult = await atomicRepository.startExternalRide(
    sessionId: 'external-finish-$suffix',
    driverId: data.driverId,
    now: data.now,
  );

  if (startResult.offerResolution !=
      AtomicExternalRideStartOfferResolution.becameBusy) {
    throw StateError('Expected becameBusy start resolution.');
  }

  await sessionRepository.addVerifiedDistance(
    driverId: data.driverId,
    segmentDistanceMeters: 300,
  );

  await sessionRepository.addVerifiedDistance(
    driverId: data.driverId,
    segmentDistanceMeters: 200,
  );

  final finishedAt = data.now.add(const Duration(minutes: 10));

  final result = await atomicRepository.finishExternalRide(
    driverId: data.driverId,
    now: finishedAt,
  );

  if (result.session.distanceMeters !=
      ExternalRideSession.qualificationDistanceMeters) {
    throw StateError('Expected exactly 500 meters.');
  }

  if (result.shouldCountTriggeredOfferAsRejection) {
    throw StateError(
      '500 meters must NOT count the triggered offer as rejection.',
    );
  }

  await _assertReturnedToAvailableBackOfQueue(
    database,
    shiftId: data.shiftId,
    expectedPriority: finishedAt,
  );

  print('distance = 500 m: OK');
  print('triggered offer does NOT count as rejection: OK');
  print('driver -> available: OK');
  print('queuePrioritySince -> finish time: OK');
}

Future<void> _checkNoTriggerNeverCountsAsRejection(
  Session database,
  PostgresAtomicExternalRideRepository atomicRepository,
  PostgresExternalRideSessionRepository sessionRepository,
) async {
  print('');
  print('SCENARIO 3: external ride started without offer');

  const driverId = 'driver-external-finish-none';
  const vehicleId = 'vehicle-external-finish-none';
  const shiftId = 'shift-external-finish-none';

  final now = DateTime.now().toUtc();

  await _createDriverVehicleAndShift(
    database,
    driverId: driverId,
    vehicleId: vehicleId,
    shiftId: shiftId,
    startedAt: now.subtract(const Duration(minutes: 20)),
    hasPendingOffer: false,
  );

  final startResult = await atomicRepository.startExternalRide(
    sessionId: 'external-finish-none',
    driverId: driverId,
    now: now,
  );

  if (startResult.offerResolution !=
      AtomicExternalRideStartOfferResolution.none) {
    throw StateError('Expected no offer resolution.');
  }

  await sessionRepository.addVerifiedDistance(
    driverId: driverId,
    segmentDistanceMeters: 100,
  );

  final finishedAt = now.add(const Duration(minutes: 5));

  final result = await atomicRepository.finishExternalRide(
    driverId: driverId,
    now: finishedAt,
  );

  if (result.shouldCountTriggeredOfferAsRejection) {
    throw StateError(
      'External ride without trigger must never count as rejection.',
    );
  }

  if (result.triggerOfferId != null || result.triggerRideId != null) {
    throw StateError('Unexpected trigger data.');
  }

  await _assertReturnedToAvailableBackOfQueue(
    database,
    shiftId: shiftId,
    expectedPriority: finishedAt,
  );

  print('no trigger offer: OK');
  print('100 m does not create rejection by itself: OK');
  print('driver -> available: OK');
  print('queuePrioritySince -> finish time: OK');
}

Future<_ScenarioData> _preparePendingOfferScenario(
  Session database, {
  required String suffix,
}) async {
  final driverId = 'driver-external-finish-$suffix';
  final vehicleId = 'vehicle-external-finish-$suffix';
  final shiftId = 'shift-external-finish-$suffix';
  final rideId = 'ride-external-finish-$suffix';
  final offerId = 'offer-external-finish-$suffix';

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

  return _ScenarioData(
    driverId: driverId,
    shiftId: shiftId,
    rideId: rideId,
    offerId: offerId,
    now: now,
  );
}

Future<void> _assertReturnedToAvailableBackOfQueue(
  Session database, {
  required String shiftId,
  required DateTime expectedPriority,
}) async {
  final result = await database.execute(
    Sql.named('''
      SELECT
        availability,
        queue_priority_since,
        has_pending_offer
      FROM driver_queue_states
      WHERE shift_id = @shiftId
    '''),
    parameters: {'shiftId': shiftId},
  );

  if (result.length != 1) {
    throw StateError('Queue state was not found.');
  }

  final row = result.single.toColumnMap();

  if (row['availability'] != 'available') {
    throw StateError('Driver did not return to available.');
  }

  if (row['has_pending_offer'] != false) {
    throw StateError('Driver returned with pending offer.');
  }

  final priority = (row['queue_priority_since'] as DateTime).toUtc();

  if (priority != expectedPriority.toUtc()) {
    throw StateError('queuePrioritySince was not updated to finish time.');
  }
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
        'External',
        'Finish',
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
        'External finish pickup',
        'External finish destination',
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

Future<void> _cleanup(Session database) async {
  await database.execute('''
      DELETE FROM external_ride_sessions
      WHERE driver_id LIKE 'driver-external-finish-%'
    ''');

  await database.execute('''
      DELETE FROM ride_offers
      WHERE driver_id LIKE 'driver-external-finish-%'
    ''');

  await database.execute('''
      DELETE FROM rides
      WHERE id LIKE 'ride-external-finish-%'
    ''');

  await database.execute('''
      DELETE FROM driver_queue_states
      WHERE shift_id LIKE 'shift-external-finish-%'
    ''');

  await database.execute('''
      DELETE FROM driver_shifts
      WHERE id LIKE 'shift-external-finish-%'
    ''');

  await database.execute('''
      DELETE FROM vehicles
      WHERE id LIKE 'vehicle-external-finish-%'
    ''');

  await database.execute('''
      DELETE FROM drivers
      WHERE id LIKE 'driver-external-finish-%'
    ''');
}

class _ScenarioData {
  final String driverId;
  final String shiftId;
  final String rideId;
  final String offerId;
  final DateTime now;

  const _ScenarioData({
    required this.driverId,
    required this.shiftId,
    required this.rideId,
    required this.offerId,
    required this.now,
  });
}

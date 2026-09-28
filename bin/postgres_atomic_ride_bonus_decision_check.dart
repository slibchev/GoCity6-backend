import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_ride_bonus_decision_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_bonus_decision_repository.dart';
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

  final repository = PostgresAtomicRideBonusDecisionRepository(
    database: connection,
  );

  try {
    await _cleanup(connection);
    await _createDriversAndVehicles(connection);

    await _checkMarkAwaitingCustomer(connection, repository);

    await _checkAcceptFiveEuroBonus(connection, repository);

    await _checkDeclineBonus(connection, repository);

    await _checkNoOfferHistoryIsBlocked(connection, repository);

    await _checkPendingOfferBlocksAwaiting(connection, repository);

    await _checkPendingOfferBlocksAccept(connection, repository);

    await _checkPendingOfferBlocksDecline(connection, repository);

    print('');
    print('PostgreSQL atomic ride bonus decision check OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _checkMarkAwaitingCustomer(
  Session database,
  PostgresAtomicRideBonusDecisionRepository repository,
) async {
  print('');
  print('SCENARIO 1: round 1 exhausted -> awaiting customer');

  const rideId = 'ride-bonus-decision-check-awaiting';

  await _createRide(database, rideId: rideId);

  await _insertRejectedRoundOneOffer(
    database,
    rideId: rideId,
    offerId: 'offer-bonus-decision-check-awaiting',
    driverId: 'driver-bonus-decision-check-1',
    vehicleId: 'vehicle-bonus-decision-check-1',
  );

  await repository.markAwaitingCustomer(rideId: rideId);

  final ride = await _readRide(database, rideId);

  if (ride['status'] != 'pending' ||
      ride['dispatch_round'] != 1 ||
      ride['driver_bonus_minor'] != 0 ||
      ride['bonus_decision'] != 'awaiting_customer') {
    throw StateError('Ride did not enter awaiting_customer correctly.');
  }

  print('ride remains pending: OK');
  print('round 1 preserved: OK');
  print('bonus remains zero: OK');
  print('bonus decision -> awaiting_customer: OK');
}

Future<void> _checkAcceptFiveEuroBonus(
  Session database,
  PostgresAtomicRideBonusDecisionRepository repository,
) async {
  print('');
  print('SCENARIO 2: customer accepts +5 EUR');

  const rideId = 'ride-bonus-decision-check-accept';

  await _createRide(database, rideId: rideId);

  await _insertRejectedRoundOneOffer(
    database,
    rideId: rideId,
    offerId: 'offer-bonus-decision-check-accept',
    driverId: 'driver-bonus-decision-check-2',
    vehicleId: 'vehicle-bonus-decision-check-2',
  );

  await repository.markAwaitingCustomer(rideId: rideId);

  await repository.acceptFiveEuroBonus(rideId: rideId);

  final ride = await _readRide(database, rideId);

  if (ride['status'] != 'pending' ||
      ride['dispatch_round'] != 2 ||
      ride['driver_bonus_minor'] != 500 ||
      ride['bonus_decision'] != 'accepted') {
    throw StateError('Accepted bonus state does not match.');
  }

  print('ride remains pending: OK');
  print('dispatch round -> 2: OK');
  print('driver bonus -> 500 cents: OK');
  print('bonus decision -> accepted: OK');
}

Future<void> _checkDeclineBonus(
  Session database,
  PostgresAtomicRideBonusDecisionRepository repository,
) async {
  print('');
  print('SCENARIO 3: customer chooses to wait');

  const rideId = 'ride-bonus-decision-check-decline';

  await _createRide(database, rideId: rideId);

  await _insertRejectedRoundOneOffer(
    database,
    rideId: rideId,
    offerId: 'offer-bonus-decision-check-decline',
    driverId: 'driver-bonus-decision-check-3',
    vehicleId: 'vehicle-bonus-decision-check-3',
  );

  await repository.markAwaitingCustomer(rideId: rideId);

  await repository.declineBonusAndMoveToWaitingForVehicle(rideId: rideId);

  final ride = await _readRide(database, rideId);

  if (ride['status'] != 'waitingForVehicle' ||
      ride['dispatch_round'] != 1 ||
      ride['driver_bonus_minor'] != 0 ||
      ride['bonus_decision'] != 'declined') {
    throw StateError('Declined bonus state does not match.');
  }

  print('status -> waitingForVehicle: OK');
  print('dispatch round remains 1: OK');
  print('bonus remains zero: OK');
  print('bonus decision -> declined: OK');
}

Future<void> _checkNoOfferHistoryIsBlocked(
  Session database,
  PostgresAtomicRideBonusDecisionRepository repository,
) async {
  print('');
  print('SCENARIO 4: no round 1 offer history');

  const rideId = 'ride-bonus-decision-check-no-history';

  await _createRide(database, rideId: rideId);

  await _expectConflict(
    () => repository.markAwaitingCustomer(rideId: rideId),
    AtomicRideBonusDecisionConflict.rideHasNoRoundOneOfferHistory,
  );

  final ride = await _readRide(database, rideId);

  if (ride['bonus_decision'] != 'not_offered') {
    throw StateError('Ride changed despite missing offer history.');
  }

  print('bonus prompt blocked without round 1 history: OK');
  print('ride state remained unchanged: OK');
}

Future<void> _checkPendingOfferBlocksAwaiting(
  Session database,
  PostgresAtomicRideBonusDecisionRepository repository,
) async {
  print('');
  print('SCENARIO 5: pending offer blocks awaiting_customer');

  const rideId = 'ride-bonus-decision-check-pending-awaiting';

  await _createRide(database, rideId: rideId);

  await _insertPendingRoundOneOffer(
    database,
    rideId: rideId,
    offerId: 'offer-bonus-decision-check-pending-awaiting',
    driverId: 'driver-bonus-decision-check-4',
    vehicleId: 'vehicle-bonus-decision-check-4',
  );

  await _expectConflict(
    () => repository.markAwaitingCustomer(rideId: rideId),
    AtomicRideBonusDecisionConflict.rideHasPendingOffer,
  );

  final ride = await _readRide(database, rideId);

  if (ride['bonus_decision'] != 'not_offered') {
    throw StateError('Ride changed while an offer was pending.');
  }

  print('pending offer blocked bonus prompt: OK');
}

Future<void> _checkPendingOfferBlocksAccept(
  Session database,
  PostgresAtomicRideBonusDecisionRepository repository,
) async {
  print('');
  print('SCENARIO 6: pending offer blocks accepting bonus');

  const rideId = 'ride-bonus-decision-check-pending-accept';

  await _createRide(
    database,
    rideId: rideId,
    bonusDecision: 'awaiting_customer',
  );

  await _insertPendingRoundOneOffer(
    database,
    rideId: rideId,
    offerId: 'offer-bonus-decision-check-pending-accept',
    driverId: 'driver-bonus-decision-check-5',
    vehicleId: 'vehicle-bonus-decision-check-5',
  );

  await _expectConflict(
    () => repository.acceptFiveEuroBonus(rideId: rideId),
    AtomicRideBonusDecisionConflict.rideHasPendingOffer,
  );

  final ride = await _readRide(database, rideId);

  if (ride['dispatch_round'] != 1 ||
      ride['driver_bonus_minor'] != 0 ||
      ride['bonus_decision'] != 'awaiting_customer') {
    throw StateError('Ride changed while bonus acceptance was blocked.');
  }

  print('pending offer blocked +5 EUR acceptance: OK');
}

Future<void> _checkPendingOfferBlocksDecline(
  Session database,
  PostgresAtomicRideBonusDecisionRepository repository,
) async {
  print('');
  print('SCENARIO 7: pending offer blocks decline');

  const rideId = 'ride-bonus-decision-check-pending-decline';

  await _createRide(
    database,
    rideId: rideId,
    bonusDecision: 'awaiting_customer',
  );

  await _insertPendingRoundOneOffer(
    database,
    rideId: rideId,
    offerId: 'offer-bonus-decision-check-pending-decline',
    driverId: 'driver-bonus-decision-check-6',
    vehicleId: 'vehicle-bonus-decision-check-6',
  );

  await _expectConflict(
    () => repository.declineBonusAndMoveToWaitingForVehicle(rideId: rideId),
    AtomicRideBonusDecisionConflict.rideHasPendingOffer,
  );

  final ride = await _readRide(database, rideId);

  if (ride['status'] != 'pending' ||
      ride['bonus_decision'] != 'awaiting_customer') {
    throw StateError('Ride changed while decline was blocked.');
  }

  print('pending offer blocked decline: OK');
  print('ride remained pending: OK');
}

Future<void> _createDriversAndVehicles(Session database) async {
  final createdAt = DateTime.now().toUtc();

  for (var i = 1; i <= 6; i++) {
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
          'Bonus',
          'Driver',
          @phone,
          TRUE,
          @createdAt
        )
      '''),
      parameters: {
        'id': 'driver-bonus-decision-check-$i',
        'username': 'bonus_decision_check_driver_$i',
        'phone': 'bonus-check-phone-$i',
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
        'id': 'vehicle-bonus-decision-check-$i',
        'plateNumber': 'BONUS-CHECK-$i',
        'createdAt': createdAt,
      },
    );
  }
}

Future<void> _createRide(
  Session database, {
  required String rideId,
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
        dispatch_round,
        driver_bonus_minor,
        bonus_decision,
        currency
      )
      VALUES (
        @id,
        'Bonus check pickup',
        'Bonus check destination',
        1,
        FALSE,
        @requestedAt,
        'pending',
        1,
        0,
        @bonusDecision,
        'EUR'
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': DateTime.now().toUtc(),
      'bonusDecision': bonusDecision,
    },
  );
}

Future<void> _insertRejectedRoundOneOffer(
  Session database, {
  required String rideId,
  required String offerId,
  required String driverId,
  required String vehicleId,
}) async {
  final offeredAt = DateTime.now().toUtc().subtract(const Duration(minutes: 1));

  final expiresAt = offeredAt.add(const Duration(seconds: 15));

  final resolvedAt = offeredAt.add(const Duration(seconds: 5));

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
        'rejected',
        @resolvedAt
      )
    '''),
    parameters: {
      'id': offerId,
      'rideId': rideId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'offeredAt': offeredAt,
      'expiresAt': expiresAt,
      'resolvedAt': resolvedAt,
    },
  );
}

Future<void> _insertPendingRoundOneOffer(
  Session database, {
  required String rideId,
  required String offerId,
  required String driverId,
  required String vehicleId,
}) async {
  final offeredAt = DateTime.now().toUtc();

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
      'expiresAt': offeredAt.add(const Duration(seconds: 15)),
    },
  );
}

Future<Map<String, dynamic>> _readRide(Session database, String rideId) async {
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
    parameters: {'rideId': rideId},
  );

  if (result.length != 1) {
    throw StateError('Ride $rideId was not found.');
  }

  return result.single.toColumnMap();
}

Future<void> _expectConflict(
  Future<void> Function() operation,
  AtomicRideBonusDecisionConflict expected,
) async {
  try {
    await operation();
  } on AtomicRideBonusDecisionConflictException catch (error) {
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

Future<void> _cleanup(Session database) async {
  await database.execute('''
      DELETE FROM ride_offers
      WHERE ride_id LIKE 'ride-bonus-decision-check-%'
    ''');

  await database.execute('''
      DELETE FROM rides
      WHERE id LIKE 'ride-bonus-decision-check-%'
    ''');

  await database.execute('''
      DELETE FROM drivers
      WHERE id LIKE 'driver-bonus-decision-check-%'
    ''');

  await database.execute('''
      DELETE FROM vehicles
      WHERE id LIKE 'vehicle-bonus-decision-check-%'
    ''');
}

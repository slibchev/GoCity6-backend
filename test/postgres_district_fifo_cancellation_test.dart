import 'dart:convert';
import 'dart:io';

import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/geography/district_matcher.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_lifecycle_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<Connection> _connectToIsolatedTestDatabase() async {
  final username = Platform.environment['CITY6_TEST_DB_USER'];
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  final port = int.tryParse(Platform.environment['CITY6_TEST_DB_PORT'] ?? '');
  if (username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    fail('CITY6_TEST_DB_USER and CITY6_TEST_DB_PASSWORD are required.');
  }
  if (port != 5433) {
    fail('This integration test is restricted to the isolated port 5433.');
  }
  final testPort = port!;

  final connection = await Connection.open(
    Endpoint(
      host: '127.0.0.1',
      port: testPort,
      database: 'city6_test',
      username: username,
      password: password,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
  final identity = await connection.execute(
    'SELECT current_database(), current_user, inet_server_port()',
  );
  expect(identity.single[0], 'city6_test');
  expect(identity.single[1], username);
  expect(identity.single[2], 5433);
  return connection;
}

void main() {
  final districtMatcher = DistrictMatcher.fromGeoJsonString(
    jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        _districtFeature(316, 'НДК', 23, 23.5),
        _districtFeature(317, 'Център', 23.5, 24),
      ],
    }),
  );

  test(
    'manual waiting-board acceptance restores the saved FIFO position',
    () async {
      final db = await _connectToIsolatedTestDatabase();
      const uuid = Uuid();
      final driverId = uuid.v4();
      final vehicleId = uuid.v4();
      final shiftId = uuid.v4();
      final rideId = uuid.v4();
      final now = DateTime.now().toUtc();
      final originalEntryAt = now.subtract(const Duration(minutes: 30));
      final originalPriorityAt = now.subtract(const Duration(hours: 1));

      try {
        await _insertDriverAndShift(
          db,
          driverId: driverId,
          vehicleId: vehicleId,
          shiftId: shiftId,
          now: now,
          districtObjectId: 316,
          districtEnteredAt: originalEntryAt,
          queuePrioritySince: originalPriorityAt,
        );
        await _insertWaitingRide(db, rideId: rideId, now: now);

        final acceptance = PostgresAtomicWaitingRideAcceptanceRepository(
          database: db,
        );
        await acceptance.acceptWaitingRide(
          rideId: rideId,
          driverId: driverId,
          now: now,
        );

        final snapshot = await db.execute(
          Sql.named('''
          SELECT manual_acceptance_shift_id,
                 manual_acceptance_district_object_id,
                 manual_acceptance_district_entered_at,
                 manual_acceptance_queue_priority_since
          FROM rides WHERE id = @rideId
        '''),
          parameters: {'rideId': rideId},
        );
        final snapshotRow = snapshot.single.toColumnMap();
        expect(snapshotRow['manual_acceptance_shift_id'], shiftId);
        expect(snapshotRow['manual_acceptance_district_object_id'], 316);
        expect(
          snapshotRow['manual_acceptance_district_entered_at'],
          originalEntryAt,
        );
        expect(
          snapshotRow['manual_acceptance_queue_priority_since'],
          originalPriorityAt,
        );

        final lifecycle = RideLifecycleService(
          repository: PostgresRideRequestRepository(
            database: db,
            districtMatcher: districtMatcher,
          ),
          now: () => now.add(const Duration(seconds: 1)),
        );
        final cancelled = await lifecycle.cancelRide(rideId);
        expect(cancelled.status, RideRequestStatus.cancelled);

        final queue = await db.execute(
          Sql.named('''
          SELECT availability, district_object_id, district_entered_at,
                 queue_priority_since, has_customer_cancellation_priority
          FROM driver_queue_states WHERE shift_id = @shiftId
        '''),
          parameters: {'shiftId': shiftId},
        );
        final queueRow = queue.single.toColumnMap();
        expect(queueRow['availability'], 'available');
        expect(queueRow['district_object_id'], 316);
        expect(queueRow['district_entered_at'], originalEntryAt);
        expect(queueRow['queue_priority_since'], originalPriorityAt);
        expect(queueRow['has_customer_cancellation_priority'], isFalse);
      } finally {
        await _cleanup(
          db,
          rideIds: [rideId],
          driverId: driverId,
          vehicleId: vehicleId,
          shiftId: shiftId,
        );
        await db.close();
      }
    },
  );

  test('manual cancellation after a confirmed district change moves the driver last', () async {
    final db = await _connectToIsolatedTestDatabase();
    const uuid = Uuid();
    final driverId = uuid.v4();
    final vehicleId = uuid.v4();
    final shiftId = uuid.v4();
    final rideId = uuid.v4();
    final now = DateTime.now().toUtc();
    final originalEntryAt = now.subtract(const Duration(minutes: 20));
    final cancellationAt = now.add(const Duration(seconds: 2));

    try {
      await _insertDriverAndShift(
        db,
        driverId: driverId,
        vehicleId: vehicleId,
        shiftId: shiftId,
        now: now,
        districtObjectId: 316,
        districtEnteredAt: originalEntryAt,
        queuePrioritySince: now.subtract(const Duration(minutes: 45)),
      );
      await _insertWaitingRide(db, rideId: rideId, now: now);
      await PostgresAtomicWaitingRideAcceptanceRepository(database: db)
          .acceptWaitingRide(rideId: rideId, driverId: driverId, now: now);

      final newDistrictEntryAt = now.add(const Duration(seconds: 1));
      await db.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET district_object_id = 317,
              district_entered_at = @enteredAt,
              district_last_observed_at = @enteredAt
          WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftId, 'enteredAt': newDistrictEntryAt},
      );

      final lifecycle = RideLifecycleService(
        repository: PostgresRideRequestRepository(
          database: db,
          districtMatcher: districtMatcher,
        ),
        now: () => cancellationAt,
      );
      await lifecycle.cancelRide(rideId);

      final queue = await db.execute(
        Sql.named('''
          SELECT district_object_id, district_entered_at,
                 queue_priority_since, has_customer_cancellation_priority
          FROM driver_queue_states WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftId},
      );
      final row = queue.single.toColumnMap();
      expect(row['district_object_id'], 317);
      expect(row['district_entered_at'], newDistrictEntryAt);
      expect(row['queue_priority_since'], cancellationAt);
      expect(row['has_customer_cancellation_priority'], isFalse);
    } finally {
      await _cleanup(
        db,
        rideIds: [rideId],
        driverId: driverId,
        vehicleId: vehicleId,
        shiftId: shiftId,
      );
      await db.close();
    }
  });

  test(
    'automatic cancellation in the dispatch district restores first priority',
    () async {
      await _verifyAutomaticCancellationCompensation(
        districtMatcher: districtMatcher,
        gpsFreshAtCancellation: true,
        expectPriority: true,
      );
    },
  );

  test(
    'automatic cancellation with stale GPS does not guess or reset FIFO',
    () async {
      await _verifyAutomaticCancellationCompensation(
        districtMatcher: districtMatcher,
        gpsFreshAtCancellation: false,
        expectPriority: false,
      );
    },
  );
}

Future<void> _verifyAutomaticCancellationCompensation({
  required DistrictMatcher districtMatcher,
  required bool gpsFreshAtCancellation,
  required bool expectPriority,
}) async {
  final db = await _connectToIsolatedTestDatabase();
  const uuid = Uuid();
  final driverId = uuid.v4();
  final vehicleId = uuid.v4();
  final shiftId = uuid.v4();
  final rideId = uuid.v4();
  final offerId = uuid.v4();
  final now = DateTime.now().toUtc();
  final districtEntryAt = now.subtract(const Duration(minutes: 20));
  final queuePriorityAt = now.subtract(const Duration(hours: 1));

  try {
    await _insertDriverAndShift(
      db,
      driverId: driverId,
      vehicleId: vehicleId,
      shiftId: shiftId,
      now: now,
      districtObjectId: 316,
      districtEnteredAt: districtEntryAt,
      queuePrioritySince: queuePriorityAt,
      latitude: 42.7,
      longitude: 23.2,
    );
    await _insertWaitingRide(db, rideId: rideId, now: now, pending: true);

    final offerRepository = PostgresAtomicRideOfferRepository(database: db);
    final offer = RideOffer.create(
      id: offerId,
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      etaSeconds: null,
      distanceMeters: null,
      dispatchDistrictObjectId: 316,
      dispatchDistrictEnteredAt: districtEntryAt,
      dispatchLocationUpdatedAt: now,
      dispatchGpsFixAt: now,
      dispatchRound: 1,
      bonusMinor: 0,
      source: RideOfferSource.automatic,
      offeredAt: now,
      timeout: const Duration(seconds: 20),
    );
    final savedOffer = await offerRepository.createPendingOffer(offer: offer);
    expect(savedOffer.etaSeconds, isNull);
    expect(savedOffer.distanceMeters, isNull);

    await offerRepository.acceptPendingOffer(
      offerId: offerId,
      now: now.add(const Duration(milliseconds: 10)),
    );

    if (!gpsFreshAtCancellation) {
      await db.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET location_updated_at = @oldAt, gps_fix_at = @oldAt
          WHERE shift_id = @shiftId
        '''),
        parameters: {
          'shiftId': shiftId,
          'oldAt': now.subtract(const Duration(minutes: 2)),
        },
      );
    }

    final lifecycle = RideLifecycleService(
      repository: PostgresRideRequestRepository(
        database: db,
        districtMatcher: districtMatcher,
      ),
      now: () => now.add(const Duration(seconds: 1)),
    );
    await lifecycle.cancelRide(rideId);

    final queue = await db.execute(
      Sql.named('''
        SELECT district_object_id, district_entered_at,
               queue_priority_since, availability,
               has_customer_cancellation_priority
        FROM driver_queue_states WHERE shift_id = @shiftId
      '''),
      parameters: {'shiftId': shiftId},
    );
    final row = queue.single.toColumnMap();
    expect(row['availability'], 'available');
    expect(row['district_object_id'], 316);
    expect(row['district_entered_at'], districtEntryAt);
    expect(row['queue_priority_since'], queuePriorityAt);
    expect(row['has_customer_cancellation_priority'], expectPriority);
  } finally {
    await _cleanup(
      db,
      rideIds: [rideId],
      driverId: driverId,
      vehicleId: vehicleId,
      shiftId: shiftId,
    );
    await db.close();
  }
}

Map<String, Object> _districtFeature(
  int objectId,
  String name,
  double west,
  double east,
) => {
  'type': 'Feature',
  'properties': {'object_id': objectId, 'id': 'uuid-$objectId', 'kvname': name},
  'geometry': {
    'type': 'Polygon',
    'coordinates': [
      [
        [west, 42.5],
        [east, 42.5],
        [east, 43],
        [west, 43],
        [west, 42.5],
      ],
    ],
  },
};

Future<void> _insertDriverAndShift(
  Connection db, {
  required String driverId,
  required String vehicleId,
  required String shiftId,
  required DateTime now,
  required int districtObjectId,
  required DateTime districtEnteredAt,
  required DateTime queuePrioritySince,
  double latitude = 42.7,
  double longitude = 23.2,
}) async {
  await db.execute(
    Sql.named('''
      INSERT INTO drivers (
        id, username, password_hash, first_name, last_name, phone, created_at
      ) VALUES (@id, @username, 'test', 'FIFO', 'Fixture', @phone, @now)
    '''),
    parameters: {
      'id': driverId,
      'username': 'fifo-$driverId',
      'phone': 'fifo-$driverId',
      'now': now,
    },
  );
  await db.execute(
    Sql.named('''
      INSERT INTO vehicles (id, plate_number, created_at)
      VALUES (@id, @plate, @now)
    '''),
    parameters: {'id': vehicleId, 'plate': 'FIFO-$vehicleId', 'now': now},
  );
  await db.execute(
    Sql.named('''
      INSERT INTO driver_shifts (
        id, driver_id, vehicle_id, started_at, protected_breaks_used
      ) VALUES (@id, @driverId, @vehicleId, @now, 0)
    '''),
    parameters: {
      'id': shiftId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'now': now,
    },
  );
  await db.execute(
    Sql.named('''
      INSERT INTO driver_queue_states (
        shift_id, availability, queue_priority_since,
        break_started_at, has_pending_offer,
        latitude, longitude, location_updated_at, gps_fix_at,
        district_object_id, district_entered_at, district_last_observed_at
      ) VALUES (
        @shiftId, 'available', @queuePriority, NULL, FALSE,
        @latitude, @longitude, @now, @now,
        @districtId, @enteredAt, @now
      )
    '''),
    parameters: {
      'shiftId': shiftId,
      'queuePriority': queuePrioritySince,
      'latitude': latitude,
      'longitude': longitude,
      'now': now,
      'districtId': districtObjectId,
      'enteredAt': districtEnteredAt,
    },
  );
}

Future<void> _insertWaitingRide(
  Connection db, {
  required String rideId,
  required DateTime now,
  bool pending = false,
}) async {
  final repository = PostgresRideRequestRepository(database: db);
  await repository.save(
    RideRequest(
      id: rideId,
      pickup: 'ул. Верила 2, София',
      pickupLatitude: 42.7,
      pickupLongitude: 23.2,
      destination: 'Paradise Center',
      passengers: 1,
      requestedAt: now.subtract(const Duration(minutes: 2)),
      status: pending
          ? RideRequestStatus.pending
          : RideRequestStatus.waitingForVehicle,
    ),
  );
}

Future<void> _cleanup(
  Connection db, {
  required List<String> rideIds,
  required String driverId,
  required String vehicleId,
  required String shiftId,
}) async {
  await db.runTx((transaction) async {
    await transaction.execute(
      Sql.named(
        'DELETE FROM driver_offer_action_outbox WHERE offer_id IN (SELECT id FROM ride_offers WHERE ride_id = ANY(@rideIds))',
      ),
      parameters: {'rideIds': rideIds},
    );
    await transaction.execute(
      Sql.named('DELETE FROM ride_reservations WHERE ride_id = ANY(@rideIds)'),
      parameters: {'rideIds': rideIds},
    );
    await transaction.execute(
      Sql.named('DELETE FROM ride_offers WHERE ride_id = ANY(@rideIds)'),
      parameters: {'rideIds': rideIds},
    );
    await transaction.execute(
      Sql.named('DELETE FROM rides WHERE id = ANY(@rideIds)'),
      parameters: {'rideIds': rideIds},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_break_requests WHERE shift_id = @shiftId'),
      parameters: {'shiftId': shiftId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_queue_states WHERE shift_id = @shiftId'),
      parameters: {'shiftId': shiftId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_shifts WHERE id = @shiftId'),
      parameters: {'shiftId': shiftId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM vehicles WHERE id = @vehicleId'),
      parameters: {'vehicleId': vehicleId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM drivers WHERE id = @driverId'),
      parameters: {'driverId': driverId},
    );
  });
}

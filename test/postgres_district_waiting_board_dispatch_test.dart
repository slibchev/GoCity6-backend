import 'dart:convert';
import 'dart:io';

import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_district_queue_service.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_district_queue_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_waiting_ride_redispatch_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/waiting_board_redispatch_service.dart';
import 'package:gocity6_backend/geography/district_matcher.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<Pool> _connectToIsolatedTestDatabase() async {
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

  final database = Pool.withEndpoints(
    [
      Endpoint(
        host: '127.0.0.1',
        port: port!,
        database: 'city6_test',
        username: username,
        password: password,
      ),
    ],
    settings: const PoolSettings(
      sslMode: SslMode.disable,
      maxConnectionCount: 5,
    ),
  );
  final identity = await database.execute(
    'SELECT current_database(), current_user, inet_server_port()',
  );
  expect(identity.single[0], 'city6_test');
  expect(identity.single[1], username);
  expect(identity.single[2], 5433);
  return database;
}

void main() {
  test('waiting-board auto dispatch stays local, retries later, and preserves manual access', () async {
    final db = await _connectToIsolatedTestDatabase();
    const uuid = Uuid();
    final now = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    final outsideDriverId = uuid.v4();
    final outsideVehicleId = uuid.v4();
    final outsideShiftId = uuid.v4();
    final ordinaryDriverId = uuid.v4();
    final ordinaryVehicleId = uuid.v4();
    final ordinaryShiftId = uuid.v4();
    final priorityDriverId = uuid.v4();
    final priorityVehicleId = uuid.v4();
    final priorityShiftId = uuid.v4();
    final staleDriverId = uuid.v4();
    final staleVehicleId = uuid.v4();
    final staleShiftId = uuid.v4();
    final localizedRideId = uuid.v4();
    final unlocatedRideId = uuid.v4();
    final matcher = _districtMatcher();
    try {
      await _cleanupAbandonedFixtures(db);
      await _insertDriverShift(
        db,
        driverId: outsideDriverId,
        vehicleId: outsideVehicleId,
        shiftId: outsideShiftId,
        usernameSuffix: 'outside',
        now: now,
        districtObjectId: 317,
        longitude: 23.8,
        availability: 'available',
        queuePrioritySince: now.subtract(const Duration(hours: 3)),
        hasCustomerCancellationPriority: false,
      );
      await _insertDriverShift(
        db,
        driverId: ordinaryDriverId,
        vehicleId: ordinaryVehicleId,
        shiftId: ordinaryShiftId,
        usernameSuffix: 'ordinary',
        now: now,
        districtObjectId: 316,
        longitude: 23.3,
        availability: 'busy',
        queuePrioritySince: now.subtract(const Duration(hours: 2)),
        hasCustomerCancellationPriority: false,
      );
      await _insertDriverShift(
        db,
        driverId: priorityDriverId,
        vehicleId: priorityVehicleId,
        shiftId: priorityShiftId,
        usernameSuffix: 'priority',
        now: now,
        districtObjectId: 316,
        longitude: 23.3,
        availability: 'busy',
        queuePrioritySince: now.subtract(const Duration(minutes: 1)),
        hasCustomerCancellationPriority: true,
      );
      await _insertDriverShift(
        db,
        driverId: staleDriverId,
        vehicleId: staleVehicleId,
        shiftId: staleShiftId,
        usernameSuffix: 'stale',
        now: now,
        districtObjectId: 316,
        longitude: 23.3,
        availability: 'available',
        queuePrioritySince: now.subtract(const Duration(hours: 4)),
        hasCustomerCancellationPriority: false,
        gpsFixAt: now.subtract(const Duration(minutes: 1)),
        lastObservedAt: now.subtract(const Duration(minutes: 1)),
      );
      await _insertRide(
        db,
        rideId: localizedRideId,
        now: now,
        pickupLatitude: 42.7,
        pickupLongitude: 23.3,
      );
      await _insertRide(
        db,
        rideId: unlocatedRideId,
        now: now,
        pickupLatitude: null,
        pickupLongitude: null,
      );

      final waitingBoard = _waitingBoardService(
        database: db,
        matcher: matcher,
        now: now,
        routeEstimator: _UnavailableRouteEstimator(),
      );

      // The only currently free driver is outside the pickup district.
      // The stale local GPS fix is also ineligible.
      expect(await waitingBoard.dispatchAvailableWaiters(at: now), isEmpty);

      final beforeLocalDriver = await db.execute(
        Sql.named('''
            SELECT COUNT(*) AS offer_count
            FROM ride_offers
            WHERE ride_id = @rideId
              AND status = 'pending'
          '''),
        parameters: {'rideId': localizedRideId},
      );
      expect(beforeLocalDriver.single.toColumnMap()['offer_count'], 0);

      // A local car becomes free. The next periodic scan selects the local
      // cancellation-priority member despite the out-of-district driver
      // having the oldest global queue timestamp and despite ETA failure.
      await db.execute(
        Sql.named('''
            UPDATE driver_queue_states
            SET availability = 'available'
            WHERE shift_id IN (@ordinaryShiftId, @priorityShiftId)
          '''),
        parameters: {
          'ordinaryShiftId': ordinaryShiftId,
          'priorityShiftId': priorityShiftId,
        },
      );
      final offers = await waitingBoard.dispatchAvailableWaiters(
        at: now.add(const Duration(seconds: 1)),
      );

      expect(offers, hasLength(1));
      expect(offers.single.driverId, priorityDriverId);
      expect(offers.single.source, RideOfferSource.waitingBoard);
      expect(offers.single.dispatchDistrictObjectId, 316);
      expect(offers.single.etaSeconds, isNull);
      expect(offers.single.distanceMeters, isNull);

      final offerRows = await db.execute(
        Sql.named('''
            SELECT driver_id, source, status,
                   dispatch_district_object_id, eta_seconds, distance_meters
            FROM ride_offers
            WHERE ride_id = @rideId
          '''),
        parameters: {'rideId': localizedRideId},
      );
      expect(offerRows, hasLength(1));
      final offerRow = offerRows.single.toColumnMap();
      expect(offerRow['driver_id'], priorityDriverId);
      expect(offerRow['source'], 'waiting_board');
      expect(offerRow['status'], 'pending');
      expect(offerRow['dispatch_district_object_id'], 316);
      expect(offerRow['eta_seconds'], isNull);
      expect(offerRow['distance_meters'], isNull);

      // A repeated scan cannot create another simultaneous offer.
      expect(
        await waitingBoard.dispatchAvailableWaiters(
          at: now.add(const Duration(seconds: 2)),
        ),
        isEmpty,
      );
      final pendingCount = await db.execute(
        Sql.named('''
            SELECT COUNT(*) AS offer_count
            FROM ride_offers
            WHERE ride_id = @rideId
              AND status = 'pending'
          '''),
        parameters: {'rideId': localizedRideId},
      );
      expect(pendingCount.single.toColumnMap()['offer_count'], 1);

      // Missing pickup coordinates never trigger a guessed district, but
      // the existing manual board selection remains available cross-district.
      final manualAcceptance = PostgresAtomicWaitingRideAcceptanceRepository(
        database: db,
      );
      final manuallyAccepted = await manualAcceptance.acceptWaitingRide(
        rideId: unlocatedRideId,
        driverId: outsideDriverId,
        now: now.add(const Duration(seconds: 3)),
      );
      expect(manuallyAccepted.assignedDriverId, outsideDriverId);

      final rideRows = await db.execute(
        Sql.named('''
            SELECT id, status, assigned_driver_id
            FROM rides
            WHERE id IN (@localizedRideId, @unlocatedRideId)
            ORDER BY id
          '''),
        parameters: {
          'localizedRideId': localizedRideId,
          'unlocatedRideId': unlocatedRideId,
        },
      );
      expect(rideRows, hasLength(2));
      expect(
        rideRows.map((row) => row.toColumnMap()['status']),
        containsAll(['waitingForVehicle', 'accepted']),
      );
    } finally {
      await _cleanup(
        db,
        rideIds: [localizedRideId, unlocatedRideId],
        driverIds: [
          outsideDriverId,
          ordinaryDriverId,
          priorityDriverId,
          staleDriverId,
        ],
        vehicleIds: [
          outsideVehicleId,
          ordinaryVehicleId,
          priorityVehicleId,
          staleVehicleId,
        ],
        shiftIds: [
          outsideShiftId,
          ordinaryShiftId,
          priorityShiftId,
          staleShiftId,
        ],
      );
      await db.close();
    }
  });
}

WaitingBoardRedispatchService _waitingBoardService({
  required Pool database,
  required DistrictMatcher matcher,
  required DateTime now,
  required RouteEstimator routeEstimator,
}) {
  final shiftRepository = PostgresDriverShiftRepository(database: database);
  final liveLocationRepository = PostgresDriverLiveLocationRepository(
    database: database,
  );
  final dispatchStateRepository = PostgresDriverDispatchStateRepository(
    database: database,
  );
  final districtQueueService = DriverDistrictQueueService(
    districtMatcher: matcher,
    repository: PostgresDriverDistrictQueueRepository(database: database),
    shiftRepository: shiftRepository,
    liveLocationRepository: liveLocationRepository,
    dispatchStateRepository: dispatchStateRepository,
  );
  final candidateService = DispatchCandidateService(
    shiftRepository: shiftRepository,
    liveLocationRepository: liveLocationRepository,
    dispatchStateRepository: dispatchStateRepository,
    routeEstimator: routeEstimator,
  );
  final offerRepository = PostgresRideOfferRepository(database: database);
  final orchestrator = AutomaticDispatchOrchestrator(
    candidateService: candidateService,
    offerRepository: offerRepository,
    atomicOfferRepository: PostgresAtomicRideOfferRepository(
      database: database,
    ),
    districtMatcher: matcher,
    findDistrictCandidates: districtQueueService.findAvailableDrivers,
    currentTime: () => DateTime.now().toUtc(),
  );
  return WaitingBoardRedispatchService(
    rideRepository: PostgresWaitingRideRedispatchRepository(database: database),
    candidateService: candidateService,
    dispatchOrchestrator: orchestrator,
    offerIdFactory: () => const Uuid().v4(),
    now: () => now,
  );
}

Future<void> _insertDriverShift(
  Pool database, {
  required String driverId,
  required String vehicleId,
  required String shiftId,
  required String usernameSuffix,
  required DateTime now,
  required int districtObjectId,
  required double longitude,
  required String availability,
  required DateTime queuePrioritySince,
  required bool hasCustomerCancellationPriority,
  DateTime? gpsFixAt,
  DateTime? lastObservedAt,
}) async {
  await database.execute(
    Sql.named('''
      INSERT INTO drivers (
        id, username, password_hash, first_name, last_name, phone, created_at
      ) VALUES (
        @driverId, @username, 'test', 'FIFO', 'Waiting', @phone, @now
      )
    '''),
    parameters: {
      'driverId': driverId,
      'username': 'district-board-$usernameSuffix-$driverId',
      'phone': 'district-board-$usernameSuffix-$driverId',
      'now': now,
    },
  );
  await database.execute(
    Sql.named('''
      INSERT INTO vehicles (id, plate_number, created_at)
      VALUES (@vehicleId, @plate, @now)
    '''),
    parameters: {
      'vehicleId': vehicleId,
      'plate': 'DB-$usernameSuffix-$vehicleId',
      'now': now,
    },
  );
  await database.execute(
    Sql.named('''
      INSERT INTO driver_shifts (
        id, driver_id, vehicle_id, started_at, protected_breaks_used
      ) VALUES (@shiftId, @driverId, @vehicleId, @now, 0)
    '''),
    parameters: {
      'shiftId': shiftId,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'now': now.subtract(const Duration(hours: 1)),
    },
  );
  final fixAt = gpsFixAt ?? now;
  await database.execute(
    Sql.named('''
      INSERT INTO driver_queue_states (
        shift_id, availability, queue_priority_since,
        break_started_at, has_pending_offer,
        latitude, longitude, location_updated_at, gps_fix_at,
        district_object_id, district_entered_at, district_last_observed_at,
        has_customer_cancellation_priority
      ) VALUES (
        @shiftId, @availability, @queuePrioritySince, NULL, FALSE,
        42.7, @longitude, @now, @gpsFixAt,
        @districtObjectId, @enteredAt, @lastObservedAt,
        @hasCustomerCancellationPriority
      )
    '''),
    parameters: {
      'shiftId': shiftId,
      'availability': availability,
      'queuePrioritySince': queuePrioritySince,
      'longitude': longitude,
      'now': now,
      'gpsFixAt': fixAt,
      'districtObjectId': districtObjectId,
      'enteredAt': now.subtract(const Duration(minutes: 30)),
      'lastObservedAt': lastObservedAt ?? fixAt,
      'hasCustomerCancellationPriority': hasCustomerCancellationPriority,
    },
  );
}

Future<void> _insertRide(
  Pool database, {
  required String rideId,
  required DateTime now,
  required double? pickupLatitude,
  required double? pickupLongitude,
}) async {
  await database.execute(
    Sql.named('''
      INSERT INTO rides (
        id, pickup, pickup_latitude, pickup_longitude,
        destination, passengers, requested_at, status
      ) VALUES (
        @rideId, 'Fixture: district waiting-board dispatch',
        @pickupLatitude, @pickupLongitude,
        'Test destination', 1, @requestedAt, 'waitingForVehicle'
      )
    '''),
    parameters: {
      'rideId': rideId,
      'pickupLatitude': pickupLatitude,
      'pickupLongitude': pickupLongitude,
      'requestedAt': now.subtract(const Duration(minutes: 5)),
    },
  );
}

Future<void> _cleanup(
  Pool database, {
  required List<String> rideIds,
  required List<String> driverIds,
  required List<String> vehicleIds,
  required List<String> shiftIds,
}) async {
  await database.runTx((transaction) async {
    await transaction.execute(
      Sql.named('''
        DELETE FROM driver_offer_action_outbox
        WHERE offer_id IN (
          SELECT id
          FROM ride_offers
          WHERE ride_id = ANY(@rideIds)
             OR driver_id = ANY(@driverIds)
             OR vehicle_id = ANY(@vehicleIds)
        )
      '''),
      parameters: {
        'rideIds': rideIds,
        'driverIds': driverIds,
        'vehicleIds': vehicleIds,
      },
    );
    await transaction.execute(
      Sql.named('''
        DELETE FROM ride_reservations
        WHERE ride_id = ANY(@rideIds)
           OR driver_id = ANY(@driverIds)
           OR vehicle_id = ANY(@vehicleIds)
      '''),
      parameters: {
        'rideIds': rideIds,
        'driverIds': driverIds,
        'vehicleIds': vehicleIds,
      },
    );
    await transaction.execute(
      Sql.named('''
        DELETE FROM ride_offers
        WHERE ride_id = ANY(@rideIds)
           OR driver_id = ANY(@driverIds)
           OR vehicle_id = ANY(@vehicleIds)
      '''),
      parameters: {
        'rideIds': rideIds,
        'driverIds': driverIds,
        'vehicleIds': vehicleIds,
      },
    );
    await transaction.execute(
      Sql.named('DELETE FROM rides WHERE id = ANY(@rideIds)'),
      parameters: {'rideIds': rideIds},
    );
    await transaction.execute(
      Sql.named(
        'DELETE FROM driver_queue_states WHERE shift_id = ANY(@shiftIds)',
      ),
      parameters: {'shiftIds': shiftIds},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_shifts WHERE id = ANY(@shiftIds)'),
      parameters: {'shiftIds': shiftIds},
    );
    await transaction.execute(
      Sql.named('DELETE FROM vehicles WHERE id = ANY(@vehicleIds)'),
      parameters: {'vehicleIds': vehicleIds},
    );
    await transaction.execute(
      Sql.named('DELETE FROM drivers WHERE id = ANY(@driverIds)'),
      parameters: {'driverIds': driverIds},
    );
  });
}

Future<void> _cleanupAbandonedFixtures(Pool database) async {
  final driverRows = await database.execute(
    "SELECT id FROM drivers WHERE username LIKE 'district-board-%'",
  );
  final driverIds = driverRows
      .map((row) => row.toColumnMap()['id'] as String)
      .toList();
  final vehicleRows = await database.execute(
    "SELECT id FROM vehicles WHERE plate_number LIKE 'DB-%'",
  );
  final vehicleIds = vehicleRows
      .map((row) => row.toColumnMap()['id'] as String)
      .toList();
  final shiftRows = await database.execute(
    Sql.named('''
      SELECT id
      FROM driver_shifts
      WHERE driver_id = ANY(@driverIds)
    '''),
    parameters: {'driverIds': driverIds},
  );
  final shiftIds = shiftRows
      .map((row) => row.toColumnMap()['id'] as String)
      .toList();
  final rideRows = await database.execute(
    Sql.named('''
      SELECT DISTINCT r.id
      FROM rides r
      LEFT JOIN ride_offers o ON o.ride_id = r.id
      LEFT JOIN ride_reservations rr ON rr.ride_id = r.id
      WHERE r.pickup = 'Fixture: district waiting-board dispatch'
        OR (
          r.pickup = 'Test pickup'
          AND (
          r.assigned_driver_id = ANY(@driverIds)
          OR o.driver_id = ANY(@driverIds)
          OR o.vehicle_id = ANY(@vehicleIds)
          OR rr.driver_id = ANY(@driverIds)
          OR rr.vehicle_id = ANY(@vehicleIds)
          )
        )
    '''),
    parameters: {'driverIds': driverIds, 'vehicleIds': vehicleIds},
  );
  final rideIds = rideRows
      .map((row) => row.toColumnMap()['id'] as String)
      .toList();

  if (driverIds.isEmpty && vehicleIds.isEmpty && rideIds.isEmpty) return;

  await _cleanup(
    database,
    rideIds: rideIds,
    driverIds: driverIds,
    vehicleIds: vehicleIds,
    shiftIds: shiftIds,
  );
}

DistrictMatcher _districtMatcher() => DistrictMatcher.fromGeoJsonString(
  jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      _districtFeature(316, 23.0, 23.5),
      _districtFeature(317, 23.5, 24.0),
    ],
  }),
);

Map<String, Object> _districtFeature(int objectId, double west, double east) =>
    {
      'type': 'Feature',
      'properties': {
        'object_id': objectId,
        'id': 'district-$objectId',
        'kvname': 'District $objectId',
      },
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [
            [west, 42.5],
            [east, 42.5],
            [east, 43.0],
            [west, 43.0],
            [west, 42.5],
          ],
        ],
      },
    };

class _UnavailableRouteEstimator implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    throw RouteEstimationFailure(RouteEstimationFailureReason.timeout);
  }
}

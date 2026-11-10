import 'dart:io';

import 'package:gocity6_backend/admin/postgres_test_driver_penalty_reset_service.dart';
import 'package:gocity6_backend/dispatch/postgres_ignored_offer_penalty_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<Connection> _connect() async {
  final username = Platform.environment['CITY6_TEST_DB_USER'];
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  final port = int.tryParse(Platform.environment['CITY6_TEST_DB_PORT'] ?? '');
  if (username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    markTestSkipped('Isolated PostgreSQL test credentials are required.');
  }
  if (port != 5433) fail('This integration test is restricted to port 5433.');

  final connection = await Connection.open(
    Endpoint(
      host: '127.0.0.1',
      port: port!,
      database: 'city6_test',
      username: username,
      password: password,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
  final identity = await connection.execute('''
    SELECT current_database(), current_schema(),
      host(inet_server_addr()), inet_server_port()
  ''');
  final identityRow = identity.single.toList();
  expect(identityRow[0], 'city6_test');
  expect(identityRow[1], 'public');
  expect(identityRow[2], anyOf('127.0.0.1', '::1'));
  expect(identityRow[3], 5433);
  return connection;
}

void main() {
  test('reset suppresses expired penalties and is idempotent', () async {
    final db = await _connect();
    final fixture = await _ResetFixture.create(db);
    try {
      final service = fixture.resetService(db);
      final result = await service.resetAll();

      expect(
        result.drivers.map((value) => value.driverId).toSet(),
        fixture.driverIds.toSet(),
      );
      expect(result.suppressedOfferCount, 3);
      for (final driverId in fixture.driverIds) {
        final state = await _state(db, driverId);
        expect(state['consecutive_rejects'], 0);
        expect(state['penalty_level'], 0);
        expect(state['dispatch_blocked_until'], isNull);
        expect(state['penalty_reset_eligible_at'], isNull);
        expect(state['requires_completed_ride_after_penalty'], isFalse);
      }

      final offerRows = await db.execute(
        Sql.named('''
          SELECT id, status, resolved_at, displayed_at
          FROM ride_offers
          WHERE id = ANY(@ids)
          ORDER BY id
        '''),
        parameters: {'ids': fixture.offerIds},
      );
      expect(offerRows.length, 3);
      expect(offerRows.where((row) => row[1] == 'expired').length, 2);
      expect(offerRows.where((row) => row[1] == 'pending').length, 1);

      final trackingRows = await db.execute(
        Sql.named('''
          SELECT offer_id, count(*)
          FROM ignored_offer_penalty_tracking
          WHERE offer_id = ANY(@ids)
          GROUP BY offer_id
        '''),
        parameters: {'ids': fixture.offerIds},
      );
      expect(trackingRows.length, 3);
      expect(trackingRows.every((row) => row[1] == 1), isTrue);

      // The normal recovery processor must now treat these events as handled.
      final penaltyService = PostgresIgnoredOfferPenaltyService(database: db);
      expect(
        await penaltyService.recordIgnoredOffer(
          offerId: fixture.expiredOfferIds.first,
          now: DateTime.now().toUtc(),
        ),
        isFalse,
      );

      final repeated = await service.resetAll();
      expect(repeated.suppressedOfferCount, 0);
      final queueRows = await db.execute(
        Sql.named('''
          SELECT q.shift_id, q.availability, q.has_pending_offer,
            q.queue_priority_since, q.district_object_id, q.district_entered_at
          FROM driver_queue_states q
          WHERE q.shift_id = ANY(@shiftIds)
          ORDER BY q.shift_id
        '''),
        parameters: {'shiftIds': fixture.shiftIds},
      );
      expect(
        queueRows.map((row) => row.toList()).toList(),
        fixture.queueSnapshot,
      );
    } finally {
      await fixture.cleanup(db);
      await db.close();
    }
  });

  test('active ride blocks whole reset without partial changes', () async {
    final db = await _connect();
    final fixture = await _ResetFixture.create(db, withActiveRide: true);
    try {
      await expectLater(
        fixture.resetService(db).resetAll(),
        throwsA(
          isA<TestDriverPenaltyResetException>().having(
            (error) => error.code,
            'code',
            'activeRide',
          ),
        ),
      );
      for (final driverId in fixture.driverIds) {
        final state = await _state(db, driverId);
        expect(state['consecutive_rejects'], 2);
        expect(state['penalty_level'], 1);
      }
      final trackingRows = await db.execute(
        Sql.named('''
          SELECT count(*) FROM ignored_offer_penalty_tracking
          WHERE offer_id = ANY(@ids)
        '''),
        parameters: {'ids': fixture.offerIds},
      );
      expect(trackingRows.single[0], 0);
    } finally {
      await fixture.cleanup(db);
      await db.close();
    }
  });

  test(
    'active offer blocks whole reset without changing queue state',
    () async {
      final db = await _connect();
      final fixture = await _ResetFixture.create(db, withActiveOffer: true);
      try {
        await expectLater(
          fixture.resetService(db).resetAll(),
          throwsA(
            isA<TestDriverPenaltyResetException>().having(
              (error) => error.code,
              'code',
              'activeOffer',
            ),
          ),
        );
        for (final driverId in fixture.driverIds) {
          final state = await _state(db, driverId);
          expect(state['consecutive_rejects'], 2);
          expect(state['penalty_level'], 1);
        }
        final offerRows = await db.execute(
          Sql.named("SELECT status FROM ride_offers WHERE id = @id"),
          parameters: {'id': fixture.activeOfferId},
        );
        expect(offerRows.single[0], 'pending');
        final queueRows = await db.execute(
          Sql.named('''
          SELECT has_pending_offer, queue_priority_since
          FROM driver_queue_states WHERE shift_id = @shiftId
        '''),
          parameters: {'shiftId': fixture.shiftIds.last},
        );
        expect(queueRows.single[0], isTrue);
        expect(
          queueRows.single[1],
          fixture.queuePriorityByShift[fixture.shiftIds.last],
        );
      } finally {
        await fixture.cleanup(db);
        await db.close();
      }
    },
  );

  test(
    'reset racing ignored-offer recovery leaves one settled event',
    () async {
      final resetDb = await _connect();
      final fixture = await _ResetFixture.create(
        resetDb,
        includePendingExpired: false,
      );
      final penaltyDb = await _connect();
      try {
        final resetService = fixture.resetService(resetDb);
        final penaltyService = PostgresIgnoredOfferPenaltyService(
          database: penaltyDb,
        );
        final offerId = fixture.expiredOfferIds.first;
        final results = await Future.wait<Object>([
          resetService.resetAll(),
          penaltyService.recordIgnoredOffer(
            offerId: offerId,
            now: DateTime.now().toUtc(),
          ),
        ]);
        expect(results, hasLength(2));

        final state = await _state(resetDb, fixture.driverIds.first);
        expect(state['consecutive_rejects'], 0);
        expect(state['penalty_level'], 0);
        final trackingRows = await resetDb.execute(
          Sql.named('''
          SELECT count(*) FROM ignored_offer_penalty_tracking
          WHERE offer_id = @id
        '''),
          parameters: {'id': offerId},
        );
        expect(trackingRows.single[0], 1);
      } finally {
        await penaltyDb.close();
        await fixture.cleanup(resetDb);
        await resetDb.close();
      }
    },
  );
}

Future<Map<String, dynamic>> _state(Connection db, String driverId) async {
  final rows = await db.execute(
    Sql.named('''
      SELECT consecutive_rejects, penalty_level, dispatch_blocked_until,
        penalty_reset_eligible_at, requires_completed_ride_after_penalty
      FROM driver_dispatch_states
      WHERE driver_id = @driverId
    '''),
    parameters: {'driverId': driverId},
  );
  return rows.single.toColumnMap();
}

class _ResetFixture {
  _ResetFixture({
    required this.driverIds,
    required this.vehicleIds,
    required this.shiftIds,
    required this.rideIds,
    required this.offerIds,
    required this.expiredOfferIds,
    required this.queueSnapshot,
    required this.queuePriorityByShift,
    required this.activeOfferId,
  });

  final List<String> driverIds;
  final List<String> vehicleIds;
  final List<String> shiftIds;
  final List<String> rideIds;
  final List<String> offerIds;
  final List<String> expiredOfferIds;
  final List<List<Object?>> queueSnapshot;
  final Map<String, DateTime> queuePriorityByShift;
  final String? activeOfferId;

  static Future<_ResetFixture> create(
    Connection db, {
    bool withActiveRide = false,
    bool withActiveOffer = false,
    bool includePendingExpired = true,
  }) => db.runTx(
    (transaction) => _createInTransaction(
      transaction,
      withActiveRide: withActiveRide,
      withActiveOffer: withActiveOffer,
      includePendingExpired: includePendingExpired,
    ),
  );

  static Future<_ResetFixture> _createInTransaction(
    TxSession db, {
    required bool withActiveRide,
    required bool withActiveOffer,
    required bool includePendingExpired,
  }) async {
    final uuid = const Uuid();
    final driverIds = List.generate(2, (_) => 'reset-${uuid.v4()}');
    final vehicleIds = List.generate(2, (_) => 'reset-${uuid.v4()}');
    final shiftIds = List.generate(2, (_) => 'reset-${uuid.v4()}');
    final expiredOfferCount = includePendingExpired ? 3 : 2;
    final rideIds = List.generate(
      expiredOfferCount + (withActiveRide ? 1 : 0) + (withActiveOffer ? 1 : 0),
      (_) => 'reset-${uuid.v4()}',
    );
    final offerIds = List.generate(
      expiredOfferCount + (withActiveOffer ? 1 : 0),
      (_) => 'reset-${uuid.v4()}',
    );
    final now = DateTime.now().toUtc();
    final queueTime = now.subtract(const Duration(hours: 1));
    final queueSnapshot = <List<Object?>>[];
    final queuePriorityByShift = <String, DateTime>{};

    for (var index = 0; index < driverIds.length; index++) {
      final driverId = driverIds[index];
      final vehicleId = vehicleIds[index];
      final shiftId = shiftIds[index];
      await db.execute(
        Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash, first_name, last_name, phone, created_at
          ) VALUES (@id, @username, 'test-hash', 'Reset', 'Fixture', @phone, @now)
        '''),
        parameters: {
          'id': driverId,
          'username': driverId,
          'phone': 'reset-$index',
          'now': now,
        },
      );
      await db.execute(
        Sql.named('''
          INSERT INTO vehicles (id, plate_number, created_at)
          VALUES (@id, @plate, @now)
        '''),
        parameters: {
          'id': vehicleId,
          'plate': 'RESET-$index-${uuid.v4()}',
          'now': now,
        },
      );
      await db.execute(
        Sql.named('''
          INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
          VALUES (@id, @driverId, @vehicleId, @now)
        '''),
        parameters: {
          'id': shiftId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'now': queueTime,
        },
      );
      await db.execute(
        Sql.named('''
          INSERT INTO driver_queue_states (
            shift_id, availability, queue_priority_since,
            district_object_id, district_entered_at, district_last_observed_at
          ) VALUES (@shiftId, 'available', @priority, 316, @entered, @observed)
        '''),
        parameters: {
          'shiftId': shiftId,
          'priority': queueTime,
          'entered': queueTime,
          'observed': now,
        },
      );
      queueSnapshot.add([
        shiftId,
        'available',
        false,
        queueTime,
        316,
        queueTime,
      ]);
      queuePriorityByShift[shiftId] = queueTime;
      await db.execute(
        Sql.named('''
          INSERT INTO driver_dispatch_states (
            driver_id, consecutive_rejects, penalty_level,
            dispatch_blocked_until, penalty_reset_eligible_at,
            requires_completed_ride_after_penalty
          ) VALUES (@id, 2, 1, @blocked, @eligible, TRUE)
        '''),
        parameters: {
          'id': driverId,
          'blocked': now.add(const Duration(minutes: 30)),
          'eligible': now.add(const Duration(hours: 8)),
        },
      );
    }

    final expiredOfferIds = <String>[];
    for (var index = 0; index < expiredOfferCount; index++) {
      final driverIndex = index % driverIds.length;
      final requestedAt = now.subtract(const Duration(minutes: 10));
      final offeredAt = now.subtract(const Duration(minutes: 2));
      final expiresAt = now.subtract(const Duration(minutes: 1));
      final isPendingExpired =
          includePendingExpired && index == expiredOfferCount - 1;
      final rideId = rideIds[index];
      final offerId = offerIds[index];
      await db.execute(
        Sql.named('''
          INSERT INTO rides (id, pickup, destination, passengers, requested_at, status)
          VALUES (@id, 'Reset test', 'Reset destination', 1, @requestedAt, 'pending')
        '''),
        parameters: {'id': rideId, 'requestedAt': requestedAt},
      );
      await db.execute(
        Sql.named('''
          INSERT INTO ride_offers (
            id, ride_id, driver_id, vehicle_id, eta_seconds, distance_meters,
            dispatch_round, offered_at, expires_at, status, resolved_at, displayed_at
          ) VALUES (
            @id, @rideId, @driverId, @vehicleId, 100, 1000,
            1, @offeredAt, @expiresAt, @status, @resolvedAt, @displayedAt
          )
        '''),
        parameters: {
          'id': offerId,
          'rideId': rideId,
          'driverId': driverIds[driverIndex],
          'vehicleId': vehicleIds[driverIndex],
          'offeredAt': offeredAt,
          'expiresAt': expiresAt,
          'status': isPendingExpired ? 'pending' : 'expired',
          'resolvedAt': isPendingExpired
              ? null
              : now.subtract(const Duration(seconds: 30)),
          'displayedAt': offeredAt.add(const Duration(seconds: 2)),
        },
      );
      if (!isPendingExpired) expiredOfferIds.add(offerId);
    }

    if (withActiveRide) {
      final activeRideId = rideIds[expiredOfferCount];
      await db.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination, passengers, requested_at, status, assigned_driver_id
          ) VALUES (@id, 'Active', 'Course', 1, @now, 'inProgress', @driverId)
        '''),
        parameters: {
          'id': activeRideId,
          'now': now,
          'driverId': driverIds.first,
        },
      );
    }

    final activeOfferId = withActiveOffer ? offerIds.last : null;
    if (activeOfferId != null) {
      final activeRideId = rideIds.last;
      await db.execute(
        Sql.named('''
          INSERT INTO rides (id, pickup, destination, passengers, requested_at, status)
          VALUES (@id, 'Active offer', 'Reset destination', 1, @now, 'pending')
        '''),
        parameters: {'id': activeRideId, 'now': now},
      );
      await db.execute(
        Sql.named('''
          INSERT INTO ride_offers (
            id, ride_id, driver_id, vehicle_id, eta_seconds, distance_meters,
            dispatch_round, offered_at, expires_at, status, resolved_at, displayed_at
          ) VALUES (
            @id, @rideId, @driverId, @vehicleId, 50, 500,
            1, @offeredAt, @expiresAt, 'pending', NULL, @displayedAt
          )
        '''),
        parameters: {
          'id': activeOfferId,
          'rideId': activeRideId,
          'driverId': driverIds.last,
          'vehicleId': vehicleIds.last,
          'offeredAt': now,
          'expiresAt': now.add(const Duration(seconds: 30)),
          'displayedAt': now,
        },
      );
      await db.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET has_pending_offer = TRUE
          WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftIds.last},
      );
    }

    return _ResetFixture(
      driverIds: driverIds,
      vehicleIds: vehicleIds,
      shiftIds: shiftIds,
      rideIds: rideIds,
      offerIds: offerIds,
      expiredOfferIds: expiredOfferIds,
      queueSnapshot: queueSnapshot
        ..sort((a, b) => (a[0] as String).compareTo(b[0] as String)),
      queuePriorityByShift: queuePriorityByShift,
      activeOfferId: activeOfferId,
    );
  }

  PostgresTestDriverPenaltyResetService resetService(Connection database) =>
      PostgresTestDriverPenaltyResetService(
        database: database,
        driverIds: driverIds,
        expectedDatabase: 'city6_test',
        expectedUsername: Platform.environment['CITY6_TEST_DB_USER']!,
        expectedPort: 5433,
      );

  Future<void> cleanup(Connection db) async {
    await db.execute(
      Sql.named(
        'DELETE FROM ignored_offer_penalty_tracking WHERE offer_id = ANY(@ids)',
      ),
      parameters: {'ids': offerIds},
    );
    await db.execute(
      Sql.named('DELETE FROM ride_offers WHERE id = ANY(@ids)'),
      parameters: {'ids': offerIds},
    );
    await db.execute(
      Sql.named('DELETE FROM rides WHERE id = ANY(@ids)'),
      parameters: {'ids': rideIds},
    );
    await db.execute(
      Sql.named('DELETE FROM driver_queue_states WHERE shift_id = ANY(@ids)'),
      parameters: {'ids': shiftIds},
    );
    await db.execute(
      Sql.named('DELETE FROM driver_shifts WHERE id = ANY(@ids)'),
      parameters: {'ids': shiftIds},
    );
    await db.execute(
      Sql.named(
        'DELETE FROM driver_dispatch_states WHERE driver_id = ANY(@ids)',
      ),
      parameters: {'ids': driverIds},
    );
    await db.execute(
      Sql.named('DELETE FROM vehicles WHERE id = ANY(@ids)'),
      parameters: {'ids': vehicleIds},
    );
    await db.execute(
      Sql.named('DELETE FROM drivers WHERE id = ANY(@ids)'),
      parameters: {'ids': driverIds},
    );
  }
}

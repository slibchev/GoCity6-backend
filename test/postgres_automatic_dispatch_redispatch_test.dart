import 'dart:async';
import 'dart:io';

import 'package:gocity6_backend/dispatch/idempotent_automatic_redispatch_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Future<Connection> _connectToCity6Test() async {
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  if (password == null || password.isEmpty) {
    fail('CITY6_TEST_DB_PASSWORD is required.');
  }
  final database = await Connection.open(
    Endpoint(
      host: 'localhost',
      port: 5432,
      database: 'city6_test',
      username: 'city6_app',
      password: password,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
  try {
    final identity = await database.execute('''
      SELECT current_database() AS database_name,
             current_user AS role_name,
             current_schema() AS schema_name
    ''');
    expect(identity.single.toColumnMap(), {
      'database_name': 'city6_test',
      'role_name': 'city6_app',
      'schema_name': 'public',
    });
    final requiredColumn = await database.execute('''
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'ride_offers'
        AND column_name = 'redispatch_action_id'
    ''');
    expect(requiredColumn, isNotEmpty, reason: 'Requires migration 017.');
    return database;
  } catch (_) {
    await database.close();
    rethrow;
  }
}

Future<Map<String, String>> _fingerprints(Session session) async {
  final tableResult = await session.execute('''
    SELECT tablename
    FROM pg_catalog.pg_tables
    WHERE schemaname = 'public'
    ORDER BY tablename
  ''');
  final tables = tableResult.map((row) => row[0] as String).toList();
  final result = <String, String>{};
  for (final table in tables) {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(table)) {
      throw StateError('Unexpected public table identifier in test database.');
    }
    final rows = await session.execute('''
      SELECT count(*)::text AS row_count,
             md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10)
               ORDER BY to_jsonb(t)::text), '')) AS fingerprint
      FROM public."$table" AS t
    ''');
    final row = rows.single.toColumnMap();
    result[table] = '${row['row_count']}:${row['fingerprint']}';
  }
  return result;
}

final class _FixtureIds {
  _FixtureIds._({
    required this.driverId,
    required this.candidateDriverId,
    required this.vehicleId,
    required this.candidateVehicleId,
    required this.shiftId,
    required this.rideId,
    required this.rejectedOfferId,
    required this.actionId,
    required this.leaseToken,
  });

  factory _FixtureIds.create() {
    const uuid = Uuid();
    return _FixtureIds._(
      driverId: uuid.v4(),
      candidateDriverId: uuid.v4(),
      vehicleId: uuid.v4(),
      candidateVehicleId: uuid.v4(),
      shiftId: uuid.v4(),
      rideId: uuid.v4(),
      rejectedOfferId: uuid.v4(),
      actionId: uuid.v4(),
      leaseToken: uuid.v4(),
    );
  }

  final String driverId;
  final String candidateDriverId;
  final String vehicleId;
  final String candidateVehicleId;
  final String shiftId;
  final String rideId;
  final String rejectedOfferId;
  final String actionId;
  final String leaseToken;
}

void main() {
  test(
    'causal offer link survives retry, expiry, and concurrent action attempts',
    () async {
      final database = await _connectToCity6Test();
      Connection? secondDatabase;
      final firstFixture = _FixtureIds.create();
      final concurrentFixture = _FixtureIds.create();
      final before = await _fingerprints(database);
      try {
        await _createFixture(database, firstFixture);
        final repository = PostgresAtomicRideOfferRepository(
          database: database,
        );
        final originalCandidate = _candidateOffer(
          firstFixture,
          offerId: const Uuid().v4(),
        );

        final created = await repository.createPendingOfferForRedispatch(
          offer: originalCandidate,
          actionId: firstFixture.actionId,
          leaseToken: firstFixture.leaseToken,
        );
        expect(created, isA<AutomaticRedispatchOfferCreated>());
        final persistedOffer =
            (created as AutomaticRedispatchOfferCreated).offer;
        final linked = await repository.findOfferByRedispatchActionId(
          firstFixture.actionId,
        );
        expect(linked?.id, persistedOffer.id);

        final beforeExpiryRetry = await repository
            .createPendingOfferForRedispatch(
              offer: _candidateOffer(firstFixture, offerId: const Uuid().v4()),
              actionId: firstFixture.actionId,
              leaseToken: 'stale-token-is-irrelevant-to-read-only-recovery',
            );
        expect(beforeExpiryRetry, isA<AutomaticRedispatchAlreadyProgressed>());
        expect(
          (beforeExpiryRetry as AutomaticRedispatchAlreadyProgressed).offer.id,
          persistedOffer.id,
        );

        await database.execute(
          Sql.named('''
            UPDATE ride_offers
            SET status = 'expired', resolved_at = expires_at
            WHERE id = @offerId AND redispatch_action_id = @actionId
          '''),
          parameters: {
            'offerId': persistedOffer.id,
            'actionId': firstFixture.actionId,
          },
        );
        await database.execute(
          Sql.named('''
            UPDATE driver_queue_states
            SET has_pending_offer = FALSE
            WHERE shift_id = @shiftId
          '''),
          parameters: {'shiftId': firstFixture.shiftId},
        );
        final expiredRetry = await repository.createPendingOfferForRedispatch(
          offer: _candidateOffer(firstFixture, offerId: const Uuid().v4()),
          actionId: firstFixture.actionId,
          leaseToken: 'expired-lease-is-irrelevant-to-read-only-recovery',
        );
        expect(expiredRetry, isA<AutomaticRedispatchAlreadyProgressed>());
        expect(
          (expiredRetry as AutomaticRedispatchAlreadyProgressed).offer.status,
          RideOfferStatus.expired,
        );
        expect(
          (await database.execute(
            Sql.named('''
              SELECT count(*)::int
              FROM ride_offers
              WHERE redispatch_action_id = @actionId
            '''),
            parameters: {'actionId': firstFixture.actionId},
          )).single[0],
          1,
        );

        await _createFixture(database, concurrentFixture);
        final concurrentRepository = PostgresAtomicRideOfferRepository(
          database: database,
        );
        await expectLater(
          concurrentRepository.createPendingOfferForRedispatch(
            offer: _candidateOffer(
              concurrentFixture,
              offerId: const Uuid().v4(),
            ),
            actionId: concurrentFixture.actionId,
            leaseToken: 'incorrect-lease-token',
          ),
          throwsA(
            isA<AutomaticRedispatchConflictException>().having(
              (error) => error.conflict,
              'conflict',
              AutomaticRedispatchConflict.leaseLost,
            ),
          ),
        );
        expect(
          await concurrentRepository.findOfferByRedispatchActionId(
            concurrentFixture.actionId,
          ),
          isNull,
        );

        secondDatabase = await _connectToCity6Test();
        final secondRepository = PostgresAtomicRideOfferRepository(
          database: secondDatabase,
        );
        final start = Completer<void>();
        Future<IdempotentAutomaticRedispatchPersistenceResult> attempt(
          PostgresAtomicRideOfferRepository target,
          String id,
        ) async {
          await start.future;
          return target.createPendingOfferForRedispatch(
            offer: _candidateOffer(concurrentFixture, offerId: id),
            actionId: concurrentFixture.actionId,
            leaseToken: concurrentFixture.leaseToken,
          );
        }

        final attemptA = attempt(concurrentRepository, const Uuid().v4());
        final attemptB = attempt(secondRepository, const Uuid().v4());
        start.complete();
        final results = await Future.wait([attemptA, attemptB]);
        expect(
          results.whereType<AutomaticRedispatchOfferCreated>(),
          hasLength(1),
        );
        expect(
          results.whereType<AutomaticRedispatchAlreadyProgressed>(),
          hasLength(1),
        );
        final concurrentOffer = await concurrentRepository
            .findOfferByRedispatchActionId(concurrentFixture.actionId);
        expect(concurrentOffer, isNotNull);
        expect(concurrentOffer?.status, RideOfferStatus.pending);
      } finally {
        try {
          await _deleteFixture(database, concurrentFixture);
          await _deleteFixture(database, firstFixture);
          final after = await _fingerprints(database);
          expect(after, equals(before));
        } finally {
          try {
            await secondDatabase?.close();
          } finally {
            await database.close();
          }
        }
      }
    },
  );
}

Future<void> _createFixture(Connection database, _FixtureIds fixture) async {
  final now = DateTime.now().toUtc();
  await database.runTx((transaction) async {
    for (final driver in [fixture.driverId, fixture.candidateDriverId]) {
      await transaction.execute(
        Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash, first_name, last_name, phone, created_at
          ) VALUES (
            @id, @username, 'redispatch-idempotency-integration-hash',
            'Redispatch-Test', 'Driver', @phone, @now
          )
        '''),
        parameters: {
          'id': driver,
          'username': 'redispatch-idempotency-$driver',
          'phone': 'redispatch-idempotency-$driver',
          'now': now,
        },
      );
    }
    for (final vehicle in [fixture.vehicleId, fixture.candidateVehicleId]) {
      await transaction.execute(
        Sql.named('''
          INSERT INTO vehicles (id, plate_number, created_at)
          VALUES (@id, @plate, @now)
        '''),
        parameters: {
          'id': vehicle,
          'plate': 'RI-${vehicle.replaceAll('-', '').substring(0, 12)}',
          'now': now,
        },
      );
    }
    await transaction.execute(
      Sql.named('''
        INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
        VALUES (@id, @driverId, @vehicleId, @startedAt)
      '''),
      parameters: {
        'id': fixture.shiftId,
        'driverId': fixture.candidateDriverId,
        'vehicleId': fixture.candidateVehicleId,
        'startedAt': now.subtract(const Duration(hours: 1)),
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO driver_queue_states (
          shift_id, availability, queue_priority_since, break_started_at,
          has_pending_offer, latitude, longitude, location_updated_at
        ) VALUES (
          @shiftId, 'available', @now, NULL, FALSE, 42.6977, 23.3219, @now
        )
      '''),
      parameters: {'shiftId': fixture.shiftId, 'now': now},
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO rides (
          id, pickup, destination, passengers, requested_at, status,
          assigned_driver_id, assigned_vehicle_id, dispatch_round,
          driver_bonus_minor, bonus_decision
        ) VALUES (
          @id, 'REDISPATCH-TEST-PICKUP', 'REDISPATCH-TEST-DESTINATION',
          1, @requestedAt, 'pending', NULL, NULL, 1, 0, 'not_offered'
        )
      '''),
      parameters: {
        'id': fixture.rideId,
        'requestedAt': now.subtract(const Duration(minutes: 2)),
      },
    );
    final offeredAt = now.subtract(const Duration(minutes: 1));
    final expiresAt = now.subtract(const Duration(seconds: 45));
    await transaction.execute(
      Sql.named('''
        INSERT INTO ride_offers (
          id, ride_id, driver_id, vehicle_id, source,
          eta_seconds, distance_meters, dispatch_round, bonus_minor,
          offered_at, expires_at, status, resolved_at, displayed_at
        ) VALUES (
          @id, @rideId, @driverId, @vehicleId, 'automatic',
          60, 500, 1, 0, @offeredAt, @expiresAt, 'rejected',
          @resolvedAt, @offeredAt
        )
      '''),
      parameters: {
        'id': fixture.rejectedOfferId,
        'rideId': fixture.rideId,
        'driverId': fixture.driverId,
        'vehicleId': fixture.vehicleId,
        'offeredAt': offeredAt,
        'expiresAt': expiresAt,
        'resolvedAt': now.subtract(const Duration(seconds: 50)),
      },
    );
    await transaction.execute(
      Sql.named('''
        INSERT INTO driver_offer_action_outbox (
          action_id, offer_id, driver_id, action, idempotency_key,
          request_hash, policy_outcome, redispatch_status, attempt_count,
          available_at, lease_token, lease_until, last_error_code,
          redispatch_result, created_at, settled_at, updated_at,
          redispatch_completed_at
        ) VALUES (
          @actionId, @offerId, @driverId, 'reject', NULL,
          repeat('a', 64), 'standard_eligible', 'leased', 1,
          @now, @leaseToken, @leaseUntil, NULL, NULL, @now, @now, @now, NULL
        )
      '''),
      parameters: {
        'actionId': fixture.actionId,
        'offerId': fixture.rejectedOfferId,
        'driverId': fixture.driverId,
        'now': now,
        'leaseToken': fixture.leaseToken,
        'leaseUntil': now.add(const Duration(minutes: 5)),
      },
    );
  });
}

RideOffer _candidateOffer(_FixtureIds fixture, {required String offerId}) {
  final offeredAt = DateTime.now().toUtc();
  return RideOffer.create(
    id: offerId,
    rideId: fixture.rideId,
    driverId: fixture.candidateDriverId,
    vehicleId: fixture.candidateVehicleId,
    etaSeconds: 90,
    distanceMeters: 600,
    dispatchRound: 1,
    bonusMinor: 0,
    source: RideOfferSource.automatic,
    offeredAt: offeredAt,
    timeout: const Duration(seconds: 15),
  );
}

Future<void> _deleteFixture(Connection database, _FixtureIds fixture) async {
  await database.runTx((transaction) async {
    await transaction.execute(
      Sql.named('''
        DELETE FROM ride_offers
        WHERE redispatch_action_id = @actionId
      '''),
      parameters: {'actionId': fixture.actionId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_offer_action_outbox WHERE action_id = @id'),
      parameters: {'id': fixture.actionId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM ride_offers WHERE id = @id'),
      parameters: {'id': fixture.rejectedOfferId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM rides WHERE id = @id'),
      parameters: {'id': fixture.rideId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_queue_states WHERE shift_id = @id'),
      parameters: {'id': fixture.shiftId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM driver_shifts WHERE id = @id'),
      parameters: {'id': fixture.shiftId},
    );
    await transaction.execute(
      Sql.named('DELETE FROM vehicles WHERE id = @firstId OR id = @secondId'),
      parameters: {
        'firstId': fixture.vehicleId,
        'secondId': fixture.candidateVehicleId,
      },
    );
    await transaction.execute(
      Sql.named('DELETE FROM drivers WHERE id = @firstId OR id = @secondId'),
      parameters: {
        'firstId': fixture.driverId,
        'secondId': fixture.candidateDriverId,
      },
    );
  });
}

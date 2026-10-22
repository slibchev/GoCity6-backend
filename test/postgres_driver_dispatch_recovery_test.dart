import 'dart:io';

import 'package:gocity6_backend/dispatch/driver_dispatch_policy_service.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';
import 'package:gocity6_backend/dispatch/driver_ride_offer_action_service.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test(
    'PostgreSQL persists 30 to 60 to 90 minute recovery escalation',
    () async {
      await _withDriver((database, driverId, now) async {
        final repository = PostgresDriverDispatchStateRepository(
          database: database,
        );
        final policy = DriverDispatchPolicyService(repository: repository);

        await policy.recordRejectedOffer(driverId: driverId, now: now);
        await policy.recordRejectedOffer(
          driverId: driverId,
          now: now.add(const Duration(seconds: 1)),
        );
        final firstPenalty = await policy.recordRejectedOffer(
          driverId: driverId,
          now: now.add(const Duration(seconds: 2)),
        );

        expect(firstPenalty.consecutiveRejects, 0);
        expect(firstPenalty.penaltyLevel, 1);
        expect(
          firstPenalty.dispatchBlockedUntil,
          now.add(const Duration(minutes: 30, seconds: 2)),
        );
        expect(firstPenalty.requiresCompletedRideAfterPenalty, isTrue);

        final secondPenalty = await policy.recordRejectedOffer(
          driverId: driverId,
          now: firstPenalty.dispatchBlockedUntil!,
        );

        expect(secondPenalty.consecutiveRejects, 0);
        expect(secondPenalty.penaltyLevel, 2);
        expect(
          secondPenalty.dispatchBlockedUntil,
          firstPenalty.dispatchBlockedUntil!.add(const Duration(minutes: 60)),
        );
        expect(secondPenalty.requiresCompletedRideAfterPenalty, isTrue);

        final thirdPenalty = await policy.recordRejectedOffer(
          driverId: driverId,
          now: secondPenalty.dispatchBlockedUntil!,
        );

        expect(thirdPenalty.consecutiveRejects, 0);
        expect(thirdPenalty.penaltyLevel, 3);
        expect(
          thirdPenalty.dispatchBlockedUntil,
          secondPenalty.dispatchBlockedUntil!.add(const Duration(minutes: 90)),
        );
        expect(thirdPenalty.requiresCompletedRideAfterPenalty, isTrue);

        final restored = await repository.findByDriverId(driverId);
        expect(restored?.penaltyLevel, 3);
        expect(restored?.requiresCompletedRideAfterPenalty, isTrue);
      });
    },
  );

  test('completed ride clears recovery and restores three rejects', () async {
    await _withDriver((database, driverId, now) async {
      final repository = PostgresDriverDispatchStateRepository(
        database: database,
      );
      final policy = DriverDispatchPolicyService(repository: repository);
      await repository.save(
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 2,
          penaltyLevel: 2,
          dispatchBlockedUntil: now.subtract(const Duration(minutes: 1)),
          penaltyResetEligibleAt: null,
          requiresCompletedRideAfterPenalty: true,
        ),
      );

      final afterRide = await policy.recordCompletedRide(driverId: driverId);
      expect(afterRide.consecutiveRejects, 0);
      expect(afterRide.penaltyLevel, 2);
      expect(afterRide.requiresCompletedRideAfterPenalty, isFalse);

      final first = await policy.recordRejectedOffer(
        driverId: driverId,
        now: now,
      );
      final second = await policy.recordRejectedOffer(
        driverId: driverId,
        now: now.add(const Duration(seconds: 1)),
      );
      expect(first.consecutiveRejects, 1);
      expect(second.consecutiveRejects, 2);
      expect(second.penaltyLevel, 2);
      expect(second.requiresCompletedRideAfterPenalty, isFalse);

      final third = await policy.recordRejectedOffer(
        driverId: driverId,
        now: now.add(const Duration(seconds: 2)),
      );
      expect(third.consecutiveRejects, 0);
      expect(third.penaltyLevel, 3);
      expect(
        third.dispatchBlockedUntil,
        now.add(const Duration(minutes: 90, seconds: 2)),
      );
      expect(third.requiresCompletedRideAfterPenalty, isTrue);
    });
  });

  test('accepting an offer does not clear persisted recovery state', () async {
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
    final uuid = const Uuid();
    final driverId = uuid.v4();
    final vehicleId = uuid.v4();
    final shiftId = uuid.v4();
    final rideId = uuid.v4();
    final offerId = uuid.v4();
    final now = DateTime.now().toUtc();

    try {
      expect(
        (await database.execute('SELECT current_database()')).single[0],
        'city6_test',
      );
      await database.execute(
        Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash,
            first_name, last_name, phone, created_at
          )
          VALUES (
            @id, @username, 'test',
            'Test', 'Acceptance', '000', @now
          )
        '''),
        parameters: {
          'id': driverId,
          'username': 'recovery-accept-$driverId',
          'now': now,
        },
      );
      await database.execute(
        Sql.named('''
          INSERT INTO vehicles (id, plate_number, created_at)
          VALUES (@id, @plate, @now)
        '''),
        parameters: {'id': vehicleId, 'plate': 'TEST-$vehicleId', 'now': now},
      );
      await database.execute(
        Sql.named('''
          INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
          VALUES (@id, @driverId, @vehicleId, @now)
        '''),
        parameters: {
          'id': shiftId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'now': now.subtract(const Duration(minutes: 1)),
        },
      );
      await database.execute(
        Sql.named('''
          INSERT INTO driver_queue_states (
            shift_id, availability, queue_priority_since, has_pending_offer
          )
          VALUES (@shiftId, 'available', @now, TRUE)
        '''),
        parameters: {'shiftId': shiftId, 'now': now},
      );
      await database.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination, passengers, requested_at, status
          )
          VALUES (
            @id, 'Acceptance pickup', 'Acceptance destination',
            1, @now, 'pending'
          )
        '''),
        parameters: {'id': rideId, 'now': now},
      );
      await database.execute(
        Sql.named('''
          INSERT INTO ride_offers (
            id, ride_id, driver_id, vehicle_id, source,
            eta_seconds, distance_meters, dispatch_round, bonus_minor,
            offered_at, expires_at, status, resolved_at
          )
          VALUES (
            @id, @rideId, @driverId, @vehicleId, 'automatic',
            60, 500, 1, 0,
            @offeredAt, @expiresAt, 'pending', NULL
          )
        '''),
        parameters: {
          'id': offerId,
          'rideId': rideId,
          'driverId': driverId,
          'vehicleId': vehicleId,
          'offeredAt': now,
          'expiresAt': now.add(const Duration(seconds: 15)),
        },
      );

      final repository = PostgresDriverDispatchStateRepository(
        database: database,
      );
      final initialState = DriverDispatchState(
        driverId: driverId,
        consecutiveRejects: 0,
        penaltyLevel: 1,
        dispatchBlockedUntil: now.subtract(const Duration(minutes: 1)),
        penaltyResetEligibleAt: null,
        requiresCompletedRideAfterPenalty: true,
      );
      await repository.save(initialState);

      final service = DriverRideOfferActionService(
        offerRepository: PostgresRideOfferRepository(database: database),
        atomicOfferRepository: PostgresAtomicRideOfferRepository(
          database: database,
        ),
        rideRepository: PostgresRideRequestRepository(database: database),
        dispatchPolicyService: DriverDispatchPolicyService(
          repository: repository,
        ),
        continueRide: ({required String rideId}) async => null,
      );
      final accepted = await service.accept(
        driverId: driverId,
        offerId: offerId,
        now: now.add(const Duration(seconds: 1)),
      );
      final persisted = await repository.findByDriverId(driverId);

      expect(accepted.status, RideOfferStatus.accepted);
      expect(persisted?.consecutiveRejects, initialState.consecutiveRejects);
      expect(persisted?.penaltyLevel, initialState.penaltyLevel);
      expect(persisted?.requiresCompletedRideAfterPenalty, isTrue);
    } finally {
      try {
        await database.runTx((transaction) async {
          await transaction.execute(
            Sql.named('DELETE FROM ride_offers WHERE id = @id'),
            parameters: {'id': offerId},
          );
          await transaction.execute(
            Sql.named(
              'DELETE FROM driver_dispatch_states WHERE driver_id = @id',
            ),
            parameters: {'id': driverId},
          );
          await transaction.execute(
            Sql.named('DELETE FROM driver_queue_states WHERE shift_id = @id'),
            parameters: {'id': shiftId},
          );
          await transaction.execute(
            Sql.named('DELETE FROM rides WHERE id = @id'),
            parameters: {'id': rideId},
          );
          await transaction.execute(
            Sql.named('DELETE FROM driver_shifts WHERE id = @id'),
            parameters: {'id': shiftId},
          );
          await transaction.execute(
            Sql.named('DELETE FROM vehicles WHERE id = @id'),
            parameters: {'id': vehicleId},
          );
          await transaction.execute(
            Sql.named('DELETE FROM drivers WHERE id = @id'),
            parameters: {'id': driverId},
          );
        });
      } finally {
        await database.close();
      }
    }
  });

  test('eight hours off shift reset the persisted recovery state', () async {
    await _withDriver((database, driverId, now) async {
      final repository = PostgresDriverDispatchStateRepository(
        database: database,
      );
      final policy = DriverDispatchPolicyService(repository: repository);
      await repository.save(
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 2,
          penaltyLevel: 3,
          dispatchBlockedUntil: now.subtract(const Duration(minutes: 1)),
          penaltyResetEligibleAt: null,
          requiresCompletedRideAfterPenalty: true,
        ),
      );

      final ended = await policy.recordShiftEnded(
        driverId: driverId,
        endedAt: now,
      );
      expect(ended.requiresCompletedRideAfterPenalty, isTrue);

      final started = await policy.recordShiftStarted(
        driverId: driverId,
        startedAt: now.add(const Duration(hours: 8)),
      );
      final persisted = await repository.findByDriverId(driverId);

      expect(started.consecutiveRejects, 0);
      expect(started.penaltyLevel, 0);
      expect(started.dispatchBlockedUntil, isNull);
      expect(started.requiresCompletedRideAfterPenalty, isFalse);
      expect(persisted?.requiresCompletedRideAfterPenalty, isFalse);
    });
  });
}

Future<void> _withDriver(
  Future<void> Function(Connection database, String driverId, DateTime now)
  body,
) async {
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
  final driverId = const Uuid().v4();
  final now = DateTime.now().toUtc();

  try {
    expect(
      (await database.execute('SELECT current_database()')).single[0],
      'city6_test',
    );
    await database.execute(
      Sql.named('''
        INSERT INTO drivers (
          id, username, password_hash,
          first_name, last_name, phone, created_at
        )
        VALUES (
          @id, @username, 'test',
          'Test', 'Recovery', '000', @now
        )
      '''),
      parameters: {
        'id': driverId,
        'username': 'recovery-$driverId',
        'now': now,
      },
    );

    await body(database, driverId, now);
  } finally {
    try {
      await database.runTx((transaction) async {
        await transaction.execute(
          Sql.named('DELETE FROM driver_dispatch_states WHERE driver_id = @id'),
          parameters: {'id': driverId},
        );
        await transaction.execute(
          Sql.named('DELETE FROM drivers WHERE id = @id'),
          parameters: {'id': driverId},
        );
      });
    } finally {
      await database.close();
    }
  }
}

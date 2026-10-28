import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_ignored_offer_penalty_service.dart';
import 'package:gocity6_backend/ride/postgres_waiting_ride_expiration_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

  test(
    'cancels due rides and invalidates active offers without touching accepted or reserved rides',
    () async {
      if (password == null || password.isEmpty) {
        markTestSkipped('CITY6_TEST_DB_PASSWORD is required for city6_test.');
      }

      final database = Pool.withEndpoints(
        [
          Endpoint(
            host: 'localhost',
            port: 5432,
            database: 'city6_test',
            username: 'city6_app',
            password: password,
          ),
        ],
        settings: const PoolSettings(
          sslMode: SslMode.disable,
          maxConnectionCount: 4,
        ),
      );

      final uuid = const Uuid();
      final rideId = uuid.v4();
      final automaticRideId = uuid.v4();
      final acceptedRideId = uuid.v4();
      final reservedRideId = uuid.v4();
      final driverId = 'expiration-test-driver-${uuid.v4()}';
      final rejectedDriverId = 'expiration-test-driver-${uuid.v4()}';
      final reservedDriverId = 'expiration-test-driver-${uuid.v4()}';
      final vehicleId = 'expiration-test-vehicle-${uuid.v4()}';
      final rejectedVehicleId = 'expiration-test-vehicle-${uuid.v4()}';
      final reservedVehicleId = 'expiration-test-vehicle-${uuid.v4()}';
      final acceptedDriverId = 'expiration-accepted-driver-${uuid.v4()}';
      final acceptedVehicleId = 'expiration-accepted-vehicle-${uuid.v4()}';
      final shiftId = 'expiration-test-shift-${uuid.v4()}';
      final rejectedShiftId = 'expiration-test-shift-${uuid.v4()}';
      final reservedShiftId = 'expiration-test-shift-${uuid.v4()}';
      final reservationId = uuid.v4();
      final rejectedOfferId = uuid.v4();
      final pendingOfferId = uuid.v4();
      final automaticOfferId = uuid.v4();
      final actionId = uuid.v4();
      var fixturesStarted = false;

      try {
        final identityResult = await database.execute(
          Sql('''
            SELECT current_database() AS database_name,
                   current_user AS user_name,
                   current_schema() AS schema_name,
                   host(inet_server_addr()) AS server_host,
                   inet_server_port() AS server_port
          '''),
        );
        final identity = identityResult.single.toColumnMap();
        expect(identity['database_name'], 'city6_test');
        expect(identity['user_name'], 'city6_app');
        expect(identity['schema_name'], 'public');
        expect(identity['server_host'], anyOf('127.0.0.1', '::1'));
        expect(identity['server_port'], 5432);

        final concurrentSessions = await database.execute(
          Sql('''
            SELECT count(*) AS session_count
            FROM pg_stat_activity
            WHERE datname = current_database()
              AND pid <> pg_backend_pid()
          '''),
        );
        expect(concurrentSessions.single[0], 0);

        final prerequisiteResult = await database.execute(
          Sql('''
            SELECT
              to_regclass('public.rides') IS NOT NULL AS has_rides,
              to_regclass('public.ride_offers') IS NOT NULL AS has_offers,
              to_regclass('public.driver_shifts') IS NOT NULL AS has_shifts,
              to_regclass('public.driver_queue_states') IS NOT NULL
                AS has_queue,
              to_regclass('public.ride_reservations') IS NOT NULL
                AS has_reservations,
              to_regclass('public.ignored_offer_penalty_tracking') IS NOT NULL
                AS has_penalty_tracking,
              to_regclass('public.driver_offer_action_outbox') IS NOT NULL
                AS has_outbox,
              to_regclass(
                'public.ride_offers_redispatch_action_id_unique_idx'
              ) IS NOT NULL AS has_migration_017
          '''),
        );
        final prerequisites = prerequisiteResult.single.toColumnMap();
        expect(prerequisites.values.every((value) => value == true), isTrue);

        final nowResult = await database.execute(
          Sql('SELECT clock_timestamp() AS database_now'),
        );
        final databaseNow =
            (nowResult.single.toColumnMap()['database_now'] as DateTime)
                .toUtc();
        final requestedAt = databaseNow.subtract(const Duration(minutes: 31));
        final queuePrioritySince = databaseNow.subtract(
          const Duration(hours: 2),
        );
        final rejectedOfferedAt = requestedAt.add(const Duration(minutes: 10));
        final rejectedExpiresAt = rejectedOfferedAt.add(
          const Duration(seconds: 15),
        );
        final rejectedResolvedAt = rejectedOfferedAt.add(
          const Duration(seconds: 5),
        );
        final pendingOfferedAt = databaseNow.subtract(
          const Duration(minutes: 1),
        );
        final pendingExpiresAt = databaseNow.add(const Duration(hours: 1));

        fixturesStarted = true;
        await database.execute(
          Sql.named('''
            INSERT INTO drivers (
              id, username, password_hash, first_name, last_name,
              phone, is_active, created_at
            ) VALUES (
              @driverId, @username, 'test-only-not-authenticatable',
              'Expiration', 'Driver', @phone, TRUE, @createdAt
            )
          '''),
          parameters: {
            'driverId': driverId,
            'username': driverId,
            'phone': '+359000000001',
            'createdAt': databaseNow,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO drivers (
              id, username, password_hash, first_name, last_name,
              phone, is_active, created_at
            ) VALUES (
              @driverId, @username, 'test-only-not-authenticatable',
              'Reserved', 'Driver', @phone, TRUE, @createdAt
            )
          '''),
          parameters: {
            'driverId': reservedDriverId,
            'username': reservedDriverId,
            'phone': '+359000000003',
            'createdAt': databaseNow,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO drivers (
              id, username, password_hash, first_name, last_name,
              phone, is_active, created_at
            ) VALUES (
              @driverId, @username, 'test-only-not-authenticatable',
              'Rejected', 'Driver', @phone, TRUE, @createdAt
            )
          '''),
          parameters: {
            'driverId': rejectedDriverId,
            'username': rejectedDriverId,
            'phone': '+359000000002',
            'createdAt': databaseNow,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO vehicles (id, plate_number, is_active, created_at)
            VALUES (@id, @plate, TRUE, @createdAt)
          '''),
          parameters: {
            'id': vehicleId,
            'plate': 'EX-${uuid.v4().substring(0, 8)}',
            'createdAt': databaseNow,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO vehicles (id, plate_number, is_active, created_at)
            VALUES (@id, @plate, TRUE, @createdAt)
          '''),
          parameters: {
            'id': reservedVehicleId,
            'plate': 'EX-${uuid.v4().substring(0, 8)}',
            'createdAt': databaseNow,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO vehicles (id, plate_number, is_active, created_at)
            VALUES (@id, @plate, TRUE, @createdAt)
          '''),
          parameters: {
            'id': rejectedVehicleId,
            'plate': 'EX-${uuid.v4().substring(0, 8)}',
            'createdAt': databaseNow,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
            VALUES (@id, @driverId, @vehicleId, @startedAt)
          '''),
          parameters: {
            'id': shiftId,
            'driverId': driverId,
            'vehicleId': vehicleId,
            'startedAt': databaseNow.subtract(const Duration(hours: 3)),
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
            VALUES (@id, @driverId, @vehicleId, @startedAt)
          '''),
          parameters: {
            'id': reservedShiftId,
            'driverId': reservedDriverId,
            'vehicleId': reservedVehicleId,
            'startedAt': databaseNow.subtract(const Duration(hours: 3)),
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO driver_shifts (id, driver_id, vehicle_id, started_at)
            VALUES (@id, @driverId, @vehicleId, @startedAt)
          '''),
          parameters: {
            'id': rejectedShiftId,
            'driverId': rejectedDriverId,
            'vehicleId': rejectedVehicleId,
            'startedAt': databaseNow.subtract(const Duration(hours: 3)),
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO driver_queue_states (
              shift_id, availability, queue_priority_since, has_pending_offer
            ) VALUES (@shiftId, 'available', @priority, TRUE)
          '''),
          parameters: {'shiftId': shiftId, 'priority': queuePrioritySince},
        );
        await database.execute(
          Sql.named('''
            INSERT INTO driver_queue_states (
              shift_id, availability, queue_priority_since, has_pending_offer
            ) VALUES (@shiftId, 'available', @priority, TRUE)
          '''),
          parameters: {
            'shiftId': rejectedShiftId,
            'priority': queuePrioritySince,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO driver_queue_states (
              shift_id, availability, queue_priority_since, has_pending_offer
            ) VALUES (@shiftId, 'busy', @priority, FALSE)
          '''),
          parameters: {
            'shiftId': reservedShiftId,
            'priority': queuePrioritySince,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO rides (
              id, pickup, destination, passengers, requested_at, status
            ) VALUES (
              @rideId, 'test pickup', 'test destination', 1,
              @requestedAt, 'waitingForVehicle'
            )
          '''),
          parameters: {'rideId': rideId, 'requestedAt': requestedAt},
        );
        await database.execute(
          Sql.named('''
            INSERT INTO rides (
              id, pickup, destination, passengers, requested_at, status
            ) VALUES (
              @rideId, 'automatic pickup', 'automatic destination', 1,
              @requestedAt, 'waitingForVehicle'
            )
          '''),
          parameters: {'rideId': automaticRideId, 'requestedAt': requestedAt},
        );
        await database.execute(
          Sql.named('''
            INSERT INTO rides (
              id, pickup, destination, passengers, requested_at, status,
              assigned_driver_id, assigned_vehicle_id
            ) VALUES (
              @rideId, 'accepted pickup', 'accepted destination', 1,
              @requestedAt, 'accepted', @driverId, @vehicleId
            )
          '''),
          parameters: {
            'rideId': acceptedRideId,
            'requestedAt': requestedAt,
            'driverId': acceptedDriverId,
            'vehicleId': acceptedVehicleId,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO rides (
              id, pickup, destination, passengers, requested_at, status
            ) VALUES (
              @rideId, 'reserved pickup', 'reserved destination', 1,
              @requestedAt, 'reserved'
            )
          '''),
          parameters: {'rideId': reservedRideId, 'requestedAt': requestedAt},
        );
        await database.execute(
          Sql.named('''
            INSERT INTO ride_reservations (
              id, ride_id, driver_id, vehicle_id, shift_id, reserved_at
            ) VALUES (
              @id, @rideId, @driverId, @vehicleId, @shiftId, @reservedAt
            )
          '''),
          parameters: {
            'id': reservationId,
            'rideId': reservedRideId,
            'driverId': reservedDriverId,
            'vehicleId': reservedVehicleId,
            'shiftId': reservedShiftId,
            'reservedAt': databaseNow.subtract(const Duration(minutes: 5)),
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO ride_offers (
              id, ride_id, driver_id, vehicle_id, eta_seconds,
              distance_meters, offered_at, expires_at, status, resolved_at
            ) VALUES (
              @id, @rideId, @driverId, @vehicleId, 60, 100,
              @offeredAt, @expiresAt, 'rejected', @resolvedAt
            )
          '''),
          parameters: {
            'id': rejectedOfferId,
            'rideId': rideId,
            'driverId': rejectedDriverId,
            'vehicleId': rejectedVehicleId,
            'offeredAt': rejectedOfferedAt,
            'expiresAt': rejectedExpiresAt,
            'resolvedAt': rejectedResolvedAt,
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO ride_offers (
              id, ride_id, driver_id, vehicle_id, eta_seconds,
              distance_meters, offered_at, expires_at, status, source,
              displayed_at
            ) VALUES (
              @id, @rideId, @driverId, @vehicleId, 60, 100,
              @offeredAt, @expiresAt, 'pending', 'waiting_board',
              @displayedAt
            )
          '''),
          parameters: {
            'id': pendingOfferId,
            'rideId': rideId,
            'driverId': driverId,
            'vehicleId': vehicleId,
            'offeredAt': pendingOfferedAt,
            'expiresAt': pendingExpiresAt,
            'displayedAt': pendingOfferedAt.add(const Duration(seconds: 1)),
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO ride_offers (
              id, ride_id, driver_id, vehicle_id, eta_seconds,
              distance_meters, offered_at, expires_at, status, source,
              displayed_at
            ) VALUES (
              @id, @rideId, @driverId, @vehicleId, 60, 100,
              @offeredAt, @expiresAt, 'pending', 'automatic', @displayedAt
            )
          '''),
          parameters: {
            'id': automaticOfferId,
            'rideId': automaticRideId,
            'driverId': rejectedDriverId,
            'vehicleId': rejectedVehicleId,
            'offeredAt': pendingOfferedAt,
            'expiresAt': pendingExpiresAt,
            'displayedAt': pendingOfferedAt.add(const Duration(seconds: 1)),
          },
        );
        await database.execute(
          Sql.named('''
            INSERT INTO driver_offer_action_outbox (
              action_id, offer_id, driver_id, action, request_hash,
              policy_outcome, redispatch_status, available_at,
              created_at, settled_at
            ) VALUES (
              @actionId, @offerId, @driverId, 'reject', @requestHash,
              'no_penalty', 'queued', @createdAt, @createdAt, @createdAt
            )
          '''),
          parameters: {
            'actionId': actionId,
            'offerId': rejectedOfferId,
            'driverId': rejectedDriverId,
            'requestHash': List.filled(64, 'a').join(),
            'createdAt': databaseNow,
          },
        );

        final expirationRepository = PostgresWaitingRideExpirationRepository(
          database: database,
        );
        final atomicOfferRepository = PostgresAtomicRideOfferRepository(
          database: database,
        );
        final acceptance = atomicOfferRepository
            .acceptPendingOffer(offerId: pendingOfferId, now: databaseNow)
            .then<Object?>(
              (offer) => offer,
              onError: (Object error, StackTrace stackTrace) => error,
            );
        final firstExpiration = expirationRepository
            .cancelExpiredWaitingRides(limit: 10)
            .then<Object?>((batch) => batch);
        await Future.wait<Object?>([acceptance, firstExpiration]);

        final acceptanceOutcome = await acceptance;
        expect(acceptanceOutcome, isA<AtomicRideOfferConflictException>());
        final acceptanceConflict =
            (acceptanceOutcome as AtomicRideOfferConflictException).conflict;
        expect(
          acceptanceConflict,
          anyOf(
            AtomicRideOfferConflict.rideTooOld,
            AtomicRideOfferConflict.offerNotPending,
            AtomicRideOfferConflict.offerAlreadyExpired,
          ),
        );

        // If acceptance held the offer row first, the expiration transaction
        // skips it and the next durable scan completes the cancellation.
        await expirationRepository.cancelExpiredWaitingRides(limit: 10);
        final settledCount = await expirationRepository
            .settleOutboxForCancelledRides(limit: 10);
        expect(settledCount, 1);

        final rideResult = await database.execute(
          Sql.named('SELECT status FROM rides WHERE id = @id'),
          parameters: {'id': rideId},
        );
        expect(rideResult.single[0], 'cancelled');
        final automaticRideResult = await database.execute(
          Sql.named('SELECT status FROM rides WHERE id = @id'),
          parameters: {'id': automaticRideId},
        );
        expect(automaticRideResult.single[0], 'cancelled');

        final protectedRideResult = await database.execute(
          Sql.named('''
            SELECT id, status
            FROM rides
            WHERE id = @acceptedRideId OR id = @reservedRideId
            ORDER BY id
          '''),
          parameters: {
            'acceptedRideId': acceptedRideId,
            'reservedRideId': reservedRideId,
          },
        );
        final protectedStatuses = {
          for (final row in protectedRideResult)
            row.toColumnMap()['id'] as String:
                row.toColumnMap()['status'] as String,
        };
        expect(protectedStatuses[acceptedRideId], 'accepted');
        expect(protectedStatuses[reservedRideId], 'reserved');
        final activeReservationResult = await database.execute(
          Sql.named('''
            SELECT count(*)
            FROM ride_reservations
            WHERE id = @id AND ended_at IS NULL
          '''),
          parameters: {'id': reservationId},
        );
        expect(activeReservationResult.single[0], 1);

        final offerResult = await database.execute(
          Sql.named('''
            SELECT status, expires_at, resolved_at, offered_at
            FROM ride_offers
            WHERE id = @id
          '''),
          parameters: {'id': pendingOfferId},
        );
        final offerRow = offerResult.single.toColumnMap();
        expect(offerRow['status'], 'expired');
        expect(
          (offerRow['resolved_at'] as DateTime).toUtc().isBefore(
            (offerRow['expires_at'] as DateTime).toUtc(),
          ),
          isFalse,
        );
        expect(
          (offerRow['expires_at'] as DateTime).toUtc().isAfter(
            (offerRow['offered_at'] as DateTime).toUtc(),
          ),
          isTrue,
        );
        final automaticOfferResult = await database.execute(
          Sql.named('''
            SELECT status
            FROM ride_offers
            WHERE id = @id
          '''),
          parameters: {'id': automaticOfferId},
        );
        expect(automaticOfferResult.single[0], 'expired');

        final queueResult = await database.execute(
          Sql.named('''
            SELECT has_pending_offer, queue_priority_since
            FROM driver_queue_states
            WHERE shift_id = @shiftId
          '''),
          parameters: {'shiftId': shiftId},
        );
        final queueRow = queueResult.single.toColumnMap();
        expect(queueRow['has_pending_offer'], isFalse);
        expect(queueRow['queue_priority_since'], queuePrioritySince);
        final rejectedDriverQueueResult = await database.execute(
          Sql.named('''
            SELECT has_pending_offer, queue_priority_since
            FROM driver_queue_states
            WHERE shift_id = @shiftId
          '''),
          parameters: {'shiftId': rejectedShiftId},
        );
        final rejectedDriverQueueRow = rejectedDriverQueueResult.single
            .toColumnMap();
        expect(rejectedDriverQueueRow['has_pending_offer'], isFalse);
        expect(
          rejectedDriverQueueRow['queue_priority_since'],
          queuePrioritySince,
        );

        final outboxResult = await database.execute(
          Sql.named('''
            SELECT redispatch_status, last_error_code, lease_token,
                   lease_until, redispatch_completed_at
            FROM driver_offer_action_outbox
            WHERE action_id = @actionId
          '''),
          parameters: {'actionId': actionId},
        );
        final outboxRow = outboxResult.single.toColumnMap();
        expect(outboxRow['redispatch_status'], 'needs_review');
        expect(outboxRow['last_error_code'], 'ride_cancelled');
        expect(outboxRow['lease_token'], isNull);
        expect(outboxRow['lease_until'], isNull);
        expect(outboxRow['redispatch_completed_at'], isNull);

        final ignoredPenaltyService = PostgresIgnoredOfferPenaltyService(
          database: database,
        );
        expect(
          await ignoredPenaltyService.recordIgnoredOffer(
            offerId: pendingOfferId,
            now: databaseNow,
          ),
          isFalse,
        );
        expect(
          await ignoredPenaltyService.recordIgnoredOffer(
            offerId: automaticOfferId,
            now: databaseNow,
          ),
          isFalse,
        );
        final dispatchStateResult = await database.execute(
          Sql.named('''
            SELECT count(*)
            FROM driver_dispatch_states
            WHERE driver_id = @driverId
          '''),
          parameters: {'driverId': driverId},
        );
        expect(dispatchStateResult.single[0], 0);

        final ignoredOfferResult = await database.execute(
          Sql.named('''
            SELECT count(*)
            FROM ignored_offer_penalty_tracking
            WHERE offer_id = @offerId
          '''),
          parameters: {'offerId': pendingOfferId},
        );
        expect(ignoredOfferResult.single[0], 0);
        final automaticIgnoredOfferResult = await database.execute(
          Sql.named('''
            SELECT count(*)
            FROM ignored_offer_penalty_tracking
            WHERE offer_id = @offerId
          '''),
          parameters: {'offerId': automaticOfferId},
        );
        expect(automaticIgnoredOfferResult.single[0], 0);

        final repeatedBatch = await expirationRepository
            .cancelExpiredWaitingRides(limit: 10);
        expect(repeatedBatch.cancelledRideIds, isEmpty);
        expect(
          await expirationRepository.settleOutboxForCancelledRides(limit: 10),
          0,
        );
      } finally {
        try {
          if (fixturesStarted) {
            await database.runTx((transaction) async {
              await transaction.execute(
                Sql.named('''
                  DELETE FROM driver_offer_action_outbox
                  WHERE action_id = @actionId
                '''),
                parameters: {'actionId': actionId},
              );
              await transaction.execute(
                Sql.named('''
                  DELETE FROM ignored_offer_penalty_tracking
                  WHERE offer_id = @offerId OR offer_id = @automaticOfferId
                '''),
                parameters: {
                  'offerId': pendingOfferId,
                  'automaticOfferId': automaticOfferId,
                },
              );
              await transaction.execute(
                Sql.named('''
                  DELETE FROM driver_dispatch_states
                  WHERE driver_id = @driverId
                     OR driver_id = @rejectedDriverId
                '''),
                parameters: {
                  'driverId': driverId,
                  'rejectedDriverId': rejectedDriverId,
                },
              );
              await transaction.execute(
                Sql.named('''
                  DELETE FROM ride_reservations
                  WHERE id = @reservationId
                '''),
                parameters: {'reservationId': reservationId},
              );
              await transaction.execute(
                Sql.named('''
                  DELETE FROM ride_offers
                  WHERE id = @pendingOfferId
                     OR id = @rejectedOfferId
                     OR id = @automaticOfferId
                '''),
                parameters: {
                  'pendingOfferId': pendingOfferId,
                  'rejectedOfferId': rejectedOfferId,
                  'automaticOfferId': automaticOfferId,
                },
              );
              await transaction.execute(
                Sql.named('''
                    DELETE FROM driver_queue_states
                    WHERE shift_id = @id
                       OR shift_id = @otherId
                       OR shift_id = @thirdId
                  '''),
                parameters: {
                  'id': shiftId,
                  'otherId': rejectedShiftId,
                  'thirdId': reservedShiftId,
                },
              );
              await transaction.execute(
                Sql.named('''
                    DELETE FROM driver_shifts
                    WHERE id = @id OR id = @otherId OR id = @thirdId
                  '''),
                parameters: {
                  'id': shiftId,
                  'otherId': rejectedShiftId,
                  'thirdId': reservedShiftId,
                },
              );
              await transaction.execute(
                Sql.named('DELETE FROM rides WHERE id = @id'),
                parameters: {'id': rideId},
              );
              await transaction.execute(
                Sql.named('DELETE FROM rides WHERE id = @id OR id = @otherId'),
                parameters: {'id': acceptedRideId, 'otherId': reservedRideId},
              );
              await transaction.execute(
                Sql.named('DELETE FROM rides WHERE id = @id'),
                parameters: {'id': automaticRideId},
              );
              await transaction.execute(
                Sql.named('''
                  DELETE FROM vehicles
                  WHERE id = @vehicleId
                     OR id = @rejectedVehicleId
                     OR id = @reservedVehicleId
                '''),
                parameters: {
                  'vehicleId': vehicleId,
                  'rejectedVehicleId': rejectedVehicleId,
                  'reservedVehicleId': reservedVehicleId,
                },
              );
              await transaction.execute(
                Sql.named('''
                  DELETE FROM drivers
                  WHERE id = @driverId
                     OR id = @rejectedDriverId
                     OR id = @reservedDriverId
                '''),
                parameters: {
                  'driverId': driverId,
                  'rejectedDriverId': rejectedDriverId,
                  'reservedDriverId': reservedDriverId,
                },
              );
            });

            final residueResult = await database.execute(
              Sql.named('''
                SELECT
                  (SELECT count(*) FROM rides WHERE id = @rideId)
                  + (SELECT count(*) FROM rides WHERE id = @automaticRideId)
                  + (SELECT count(*) FROM rides
                     WHERE id = @acceptedRideId OR id = @reservedRideId)
                  + (SELECT count(*) FROM ride_offers
                     WHERE id = @pendingOfferId
                        OR id = @rejectedOfferId
                        OR id = @automaticOfferId)
                  + (SELECT count(*) FROM driver_offer_action_outbox
                     WHERE action_id = @actionId)
                  + (SELECT count(*) FROM ignored_offer_penalty_tracking
                     WHERE offer_id = @pendingOfferId)
                  + (SELECT count(*) FROM ignored_offer_penalty_tracking
                     WHERE offer_id = @automaticOfferId)
                  + (SELECT count(*) FROM driver_queue_states
                     WHERE shift_id = @shiftId
                        OR shift_id = @rejectedShiftId
                        OR shift_id = @reservedShiftId)
                  + (SELECT count(*) FROM ride_reservations
                     WHERE id = @reservationId)
                  + (SELECT count(*) FROM driver_shifts
                     WHERE id = @shiftId
                        OR id = @rejectedShiftId
                        OR id = @reservedShiftId)
                  + (SELECT count(*) FROM driver_dispatch_states
                     WHERE driver_id = @driverId
                        OR driver_id = @rejectedDriverId)
                  + (SELECT count(*) FROM vehicles
                     WHERE id = @vehicleId
                        OR id = @rejectedVehicleId
                        OR id = @reservedVehicleId)
                  + (SELECT count(*) FROM drivers
                     WHERE id = @driverId
                        OR id = @rejectedDriverId
                        OR id = @reservedDriverId)
                  AS fixture_residue
              '''),
              parameters: {
                'rideId': rideId,
                'automaticRideId': automaticRideId,
                'acceptedRideId': acceptedRideId,
                'reservedRideId': reservedRideId,
                'pendingOfferId': pendingOfferId,
                'rejectedOfferId': rejectedOfferId,
                'automaticOfferId': automaticOfferId,
                'actionId': actionId,
                'shiftId': shiftId,
                'rejectedShiftId': rejectedShiftId,
                'reservedShiftId': reservedShiftId,
                'reservationId': reservationId,
                'driverId': driverId,
                'rejectedDriverId': rejectedDriverId,
                'reservedDriverId': reservedDriverId,
                'vehicleId': vehicleId,
                'rejectedVehicleId': rejectedVehicleId,
                'reservedVehicleId': reservedVehicleId,
              },
            );
            expect(residueResult.single[0], 0);
          }
        } finally {
          await database.close();
        }
      }
    },
    skip: password == null || password.isEmpty
        ? 'CITY6_TEST_DB_PASSWORD is required for city6_test.'
        : false,
  );
}

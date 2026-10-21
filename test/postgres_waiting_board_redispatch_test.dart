import 'dart:io';

import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test(
    'waiting-board offers are exclusive and preserve accepted bonus',
    () async {
      final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

      if (password == null || password.isEmpty) {
        fail('CITY6_TEST_DB_PASSWORD is required.');
      }

      final db = await Connection.open(
        Endpoint(
          host: 'localhost',
          port: 5432,
          database: 'city6_test',
          username: 'city6_app',
          password: password,
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      const uuid = Uuid();
      final driverId = uuid.v4();
      final vehicleId = uuid.v4();
      final shiftId = uuid.v4();
      final rideId = uuid.v4();
      final expiredBoundaryRideId = uuid.v4();
      final staleGpsRideId = uuid.v4();
      final offerId = uuid.v4();
      final expiredBoundaryOfferId = uuid.v4();
      final staleGpsOfferId = uuid.v4();
      final offeredAt = DateTime.now().toUtc();
      final requestedAt = offeredAt.subtract(const Duration(minutes: 5));

      try {
        final databaseName = await db.execute('SELECT current_database()');
        expect(databaseName.single[0], 'city6_test');

        await db.execute(
          Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash,
            first_name, last_name, phone, created_at
          )
          VALUES (
            @id, @username, 'test', 'Waiting', 'Driver', '000', @now
          )
        '''),
          parameters: {
            'id': driverId,
            'username': 'waiting-$driverId',
            'now': offeredAt,
          },
        );
        await db.execute(
          Sql.named('''
          INSERT INTO vehicles (id, plate_number, created_at)
          VALUES (@id, @plate, @now)
        '''),
          parameters: {
            'id': vehicleId,
            'plate': 'WAIT-$vehicleId',
            'now': offeredAt,
          },
        );
        await db.execute(
          Sql.named('''
          INSERT INTO driver_shifts (
            id, driver_id, vehicle_id, started_at, protected_breaks_used
          )
          VALUES (@shiftId, @driverId, @vehicleId, @now, 0)
        '''),
          parameters: {
            'shiftId': shiftId,
            'driverId': driverId,
            'vehicleId': vehicleId,
            'now': offeredAt,
          },
        );
        await db.execute(
          Sql.named('''
          INSERT INTO driver_queue_states (
            shift_id, availability, queue_priority_since,
            break_started_at, has_pending_offer,
            latitude, longitude, location_updated_at
          )
          VALUES (@shiftId, 'available', @now, NULL, FALSE,
                  42.6977, 23.3219, NOW())
        '''),
          parameters: {'shiftId': shiftId, 'now': offeredAt},
        );
        await _insertRide(
          db,
          rideId: rideId,
          requestedAt: requestedAt,
          dispatchRound: RideOffer.bonusDispatchRound,
          bonusMinor: RideOffer.shortRideBonusMinor,
          bonusDecision: 'accepted',
        );

        final atomicOffers = PostgresAtomicRideOfferRepository(database: db);
        final boardOffer = RideOffer.create(
          id: offerId,
          rideId: rideId,
          driverId: driverId,
          vehicleId: vehicleId,
          etaSeconds: 120,
          distanceMeters: 800,
          dispatchRound: RideOffer.bonusDispatchRound,
          bonusMinor: RideOffer.shortRideBonusMinor,
          source: RideOfferSource.waitingBoard,
          offeredAt: offeredAt,
          timeout: const Duration(seconds: 15),
        );
        await atomicOffers.createPendingOffer(offer: boardOffer);

        final board = await PostgresRideRequestRepository(database: db)
            .findWaitingForVehicle();
        expect(board.any((ride) => ride.id == rideId), isFalse);

        final manualAcceptance = PostgresAtomicWaitingRideAcceptanceRepository(
          database: db,
        );
        await expectLater(
          manualAcceptance.acceptWaitingRide(
            rideId: rideId,
            driverId: driverId,
            now: offeredAt.add(const Duration(seconds: 1)),
          ),
          throwsA(
            isA<AtomicWaitingRideAcceptanceConflictException>().having(
              (error) => error.conflict,
              'conflict',
              AtomicWaitingRideAcceptanceConflict.activeAutomaticOffer,
            ),
          ),
        );

        await expectLater(
          PostgresAtomicRideReservationRepository(database: db)
              .reserveWaitingRide(
                reservationId: uuid.v4(),
                rideId: rideId,
                driverId: 'driver-without-shift',
                combinedEtaSeconds: 120,
                now: offeredAt.add(const Duration(seconds: 1)),
              ),
          throwsA(
            isA<AtomicRideReservationConflictException>().having(
              (error) => error.conflict,
              'conflict',
              AtomicRideReservationConflict.activeAutomaticOffer,
            ),
          ),
        );

        final acceptedOffer = await atomicOffers.acceptPendingOffer(
          offerId: offerId,
          now: offeredAt.add(const Duration(seconds: 5)),
        );
        expect(acceptedOffer.source, RideOfferSource.waitingBoard);
        expect(
          acceptedOffer.expiresAt.difference(acceptedOffer.offeredAt),
          const Duration(seconds: 15),
        );

        final acceptedRide = await db.execute(
          Sql.named('''
          SELECT status, assigned_driver_id, dispatch_round,
                 driver_bonus_minor, bonus_decision
          FROM rides
          WHERE id = @rideId
        '''),
          parameters: {'rideId': rideId},
        );
        final rideRow = acceptedRide.single.toColumnMap();
        expect(rideRow['status'], 'accepted');
        expect(rideRow['assigned_driver_id'], driverId);
        expect(rideRow['dispatch_round'], RideOffer.bonusDispatchRound);
        expect(rideRow['driver_bonus_minor'], RideOffer.shortRideBonusMinor);
        expect(rideRow['bonus_decision'], 'accepted');

        await _insertRide(
          db,
          rideId: expiredBoundaryRideId,
          // Stay safely past the cutoff so DB setup time cannot affect this.
          requestedAt: offeredAt.subtract(
            const Duration(minutes: 30, seconds: 5),
          ),
          dispatchRound: RideOffer.normalDispatchRound,
          bonusMinor: RideOffer.noBonusMinor,
          bonusDecision: 'not_offered',
        );
        await expectLater(
          manualAcceptance.acceptWaitingRide(
            rideId: expiredBoundaryRideId,
            driverId: driverId,
            now: offeredAt,
          ),
          throwsA(
            isA<AtomicWaitingRideAcceptanceConflictException>().having(
              (error) => error.conflict,
              'conflict',
              AtomicWaitingRideAcceptanceConflict.rideTooOld,
            ),
          ),
        );
        await expectLater(
          PostgresAtomicRideReservationRepository(database: db)
              .reserveWaitingRide(
                reservationId: uuid.v4(),
                rideId: expiredBoundaryRideId,
                driverId: driverId,
                combinedEtaSeconds: 120,
                now: offeredAt,
              ),
          throwsA(
            isA<AtomicRideReservationConflictException>().having(
              (error) => error.conflict,
              'conflict',
              AtomicRideReservationConflict.rideTooOld,
            ),
          ),
        );
        await expectLater(
          atomicOffers.createPendingOffer(
            offer: RideOffer.create(
              id: expiredBoundaryOfferId,
              rideId: expiredBoundaryRideId,
              driverId: driverId,
              vehicleId: vehicleId,
              etaSeconds: 120,
              distanceMeters: 800,
              source: RideOfferSource.waitingBoard,
              offeredAt: offeredAt,
              timeout: const Duration(seconds: 15),
            ),
          ),
          throwsA(
            isA<AtomicRideOfferConflictException>().having(
              (error) => error.conflict,
              'conflict',
              AtomicRideOfferConflict.rideTooOld,
            ),
          ),
        );

        await _insertRide(
          db,
          rideId: staleGpsRideId,
          requestedAt: offeredAt.subtract(const Duration(minutes: 5)),
          dispatchRound: RideOffer.normalDispatchRound,
          bonusMinor: RideOffer.noBonusMinor,
          bonusDecision: 'not_offered',
        );
        await db.execute(
          Sql.named('''
          UPDATE driver_queue_states
          SET availability = 'available', has_pending_offer = FALSE,
              location_updated_at = clock_timestamp() - INTERVAL '31 seconds'
          WHERE shift_id = @shiftId
        '''),
          parameters: {'shiftId': shiftId},
        );
        await expectLater(
          atomicOffers.createPendingOffer(
            offer: RideOffer.create(
              id: staleGpsOfferId,
              rideId: staleGpsRideId,
              driverId: driverId,
              vehicleId: vehicleId,
              etaSeconds: 120,
              distanceMeters: 800,
              source: RideOfferSource.waitingBoard,
              offeredAt: offeredAt,
              timeout: const Duration(seconds: 15),
            ),
          ),
          throwsA(
            isA<AtomicRideOfferConflictException>().having(
              (error) => error.conflict,
              'conflict',
              AtomicRideOfferConflict.driverLocationStale,
            ),
          ),
        );
      } finally {
        await db.execute(
          Sql.named(
            'DELETE FROM ride_offers WHERE ride_id IN '
            '(@rideId, @oldRideId, @staleRideId)',
          ),
          parameters: {
            'rideId': rideId,
            'oldRideId': expiredBoundaryRideId,
            'staleRideId': staleGpsRideId,
          },
        );
        await db.execute(
          Sql.named(
            'DELETE FROM rides WHERE id IN '
            '(@rideId, @oldRideId, @staleRideId)',
          ),
          parameters: {
            'rideId': rideId,
            'oldRideId': expiredBoundaryRideId,
            'staleRideId': staleGpsRideId,
          },
        );
        await db.execute(
          Sql.named(
            'DELETE FROM driver_queue_states WHERE shift_id = @shiftId',
          ),
          parameters: {'shiftId': shiftId},
        );
        await db.execute(
          Sql.named('DELETE FROM driver_shifts WHERE id = @shiftId'),
          parameters: {'shiftId': shiftId},
        );
        await db.execute(
          Sql.named('DELETE FROM vehicles WHERE id = @vehicleId'),
          parameters: {'vehicleId': vehicleId},
        );
        await db.execute(
          Sql.named('DELETE FROM drivers WHERE id = @driverId'),
          parameters: {'driverId': driverId},
        );
        await db.close();
      }
    },
  );
}

Future<void> _insertRide(
  Connection db, {
  required String rideId,
  required DateTime requestedAt,
  required int dispatchRound,
  required int bonusMinor,
  required String bonusDecision,
}) async {
  await db.execute(
    Sql.named('''
      INSERT INTO rides (
        id, pickup, destination, passengers, requested_at, status,
        dispatch_round, driver_bonus_minor, bonus_decision
      )
      VALUES (
        @id, 'Test pickup', 'Test destination', 1, @requestedAt,
        'waitingForVehicle', @dispatchRound, @bonusMinor, @bonusDecision
      )
    '''),
    parameters: {
      'id': rideId,
      'requestedAt': requestedAt,
      'dispatchRound': dispatchRound,
      'bonusMinor': bonusMinor,
      'bonusDecision': bonusDecision,
    },
  );
}

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/postgres_atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_work_state_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_waiting_ride_redispatch_repository.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_lifecycle_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';

const _pickupLatitude = 42.6977123;
const _pickupLongitude = 23.3219876;

Future<Connection> _connectToCity6Test() async {
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

  try {
    final result = await db.execute('SELECT current_database()');
    expect(result.single[0], 'city6_test');
    return db;
  } catch (_) {
    await db.close();
    rethrow;
  }
}

RideRequest _waitingRide({
  required String id,
  required DateTime requestedAt,
  double? latitude,
  double? longitude,
  String? clientRequestId,
  int dispatchRound = RideRequest.normalDispatchRound,
  int driverBonusMinor = RideRequest.noDriverBonusMinor,
  RideBonusDecision bonusDecision = RideBonusDecision.notOffered,
}) {
  return RideRequest(
    id: id,
    clientRequestId: clientRequestId,
    pickup: latitude == null ? 'Legacy address-only pickup' : 'My location',
    pickupLatitude: latitude,
    pickupLongitude: longitude,
    destination: 'Test destination',
    passengers: 1,
    requestedAt: requestedAt,
    status: RideRequestStatus.waitingForVehicle,
    dispatchRound: dispatchRound,
    driverBonusMinor: driverBonusMinor,
    bonusDecision: bonusDecision,
  );
}

void main() {
  test(
    'PostgreSQL pickup coordinates survive lifecycle and repository reads',
    () async {
      final db = await _connectToCity6Test();
      final uuid = const Uuid();
      final driverId = uuid.v4();
      final vehicleId = uuid.v4();
      final shiftId = uuid.v4();
      final reservationId = uuid.v4();
      final currentRideId = uuid.v4();
      final reservedRideId = uuid.v4();
      final waitingRideId = uuid.v4();
      final legacyRideId = uuid.v4();
      final now = DateTime.now().toUtc();
      final requestedAt = now.subtract(const Duration(minutes: 2));
      final rideIds = [
        currentRideId,
        reservedRideId,
        waitingRideId,
        legacyRideId,
      ];

      try {
        await db.execute(
          Sql.named('''
            INSERT INTO drivers (
              id, username, password_hash,
              first_name, last_name, phone, created_at
            )
            VALUES (
              @id, @username, 'test',
              'GPS', 'Fixture Driver', @phone, @now
            )
          '''),
          parameters: {
            'id': driverId,
            'username': 'pickup-coordinates-$driverId',
            'phone': 'pickup-coordinates-$driverId',
            'now': now,
          },
        );

        await db.execute(
          Sql.named('''
            INSERT INTO vehicles (id, plate_number, created_at)
            VALUES (@id, @plate, @now)
          '''),
          parameters: {'id': vehicleId, 'plate': 'GPS-$vehicleId', 'now': now},
        );

        await db.execute(
          Sql.named('''
            INSERT INTO driver_shifts (
              id, driver_id, vehicle_id,
              started_at, protected_breaks_used
            )
            VALUES (@id, @driverId, @vehicleId, @now, 0)
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
              break_started_at, has_pending_offer
            )
            VALUES (@shiftId, 'available', @now, NULL, FALSE)
          '''),
          parameters: {'shiftId': shiftId, 'now': now},
        );

        final rideRepository = PostgresRideRequestRepository(database: db);
        await rideRepository.save(
          _waitingRide(
            id: currentRideId,
            requestedAt: requestedAt,
            latitude: _pickupLatitude,
            longitude: _pickupLongitude,
          ),
        );
        await rideRepository.save(
          _waitingRide(
            id: reservedRideId,
            requestedAt: requestedAt.add(const Duration(milliseconds: 1)),
            latitude: _pickupLatitude + 0.001,
            longitude: _pickupLongitude + 0.001,
            dispatchRound: RideRequest.bonusDispatchRound,
            driverBonusMinor: RideRequest.driverBonusFiveEuroMinor,
            bonusDecision: RideBonusDecision.accepted,
          ),
        );
        await rideRepository.save(
          _waitingRide(
            id: waitingRideId,
            requestedAt: requestedAt.add(const Duration(milliseconds: 2)),
            latitude: _pickupLatitude + 0.002,
            longitude: _pickupLongitude + 0.002,
            clientRequestId: uuid.v4(),
            dispatchRound: RideRequest.bonusDispatchRound,
            driverBonusMinor: RideRequest.driverBonusFiveEuroMinor,
            bonusDecision: RideBonusDecision.accepted,
          ),
        );
        await rideRepository.save(
          _waitingRide(
            id: legacyRideId,
            requestedAt: requestedAt.add(const Duration(milliseconds: 3)),
          ),
        );

        final savedCoordinateRide = await rideRepository.findById(
          currentRideId,
        );
        expect(savedCoordinateRide, isNotNull);
        expect(savedCoordinateRide!.pickupLatitude, _pickupLatitude);
        expect(savedCoordinateRide.pickupLongitude, _pickupLongitude);

        final waitingBoard = PostgresWaitingRideRedispatchRepository(
          database: db,
        );
        final boardRides = await waitingBoard.findOldestPage(
          notBefore: requestedAt.subtract(const Duration(seconds: 1)),
          limit: 200,
        );
        final boardById = {for (final ride in boardRides) ride.id: ride};
        expect(boardById[currentRideId]?.pickupLatitude, _pickupLatitude);
        expect(boardById[currentRideId]?.pickupLongitude, _pickupLongitude);
        expect(
          boardById[waitingRideId]?.pickupLatitude,
          _pickupLatitude + 0.002,
        );
        expect(
          boardById[waitingRideId]?.pickupLongitude,
          _pickupLongitude + 0.002,
        );
        expect(boardById[waitingRideId]?.dispatchRound, 2);
        expect(boardById[waitingRideId]?.driverBonusMinor, 500);
        expect(boardById[legacyRideId]?.pickupLatitude, isNull);
        expect(boardById[legacyRideId]?.pickupLongitude, isNull);

        final acceptanceRepository =
            PostgresAtomicWaitingRideAcceptanceRepository(database: db);
        final acceptedRide = await acceptanceRepository.acceptWaitingRide(
          rideId: currentRideId,
          driverId: driverId,
          now: now,
        );
        expect(acceptedRide.status, RideRequestStatus.accepted);
        expect(acceptedRide.pickupLatitude, _pickupLatitude);
        expect(acceptedRide.pickupLongitude, _pickupLongitude);

        final workStateRepository = PostgresDriverWorkStateRepository(
          database: db,
        );
        var workState = await workStateRepository.loadByDriverId(driverId);
        expect(workState.currentRide?.id, currentRideId);
        expect(workState.currentRide?.pickupLatitude, _pickupLatitude);
        expect(workState.currentRide?.pickupLongitude, _pickupLongitude);

        final lifecycle = RideLifecycleService(
          repository: rideRepository,
          now: () => now,
        );
        final arrivingRide = await lifecycle.markDriverArriving(
          rideId: currentRideId,
          driverId: driverId,
        );
        expect(arrivingRide.pickupLatitude, _pickupLatitude);
        expect(arrivingRide.pickupLongitude, _pickupLongitude);
        final inProgressRide = await lifecycle.startRide(
          rideId: currentRideId,
          driverId: driverId,
        );
        expect(inProgressRide.pickupLatitude, _pickupLatitude);
        expect(inProgressRide.pickupLongitude, _pickupLongitude);

        final reservationRepository = PostgresAtomicRideReservationRepository(
          database: db,
        );
        final reservation = await reservationRepository.reserveWaitingRide(
          reservationId: reservationId,
          rideId: reservedRideId,
          driverId: driverId,
          combinedEtaSeconds: 300,
          now: now,
        );
        expect(reservation.rideId, reservedRideId);
        workState = await workStateRepository.loadByDriverId(driverId);
        expect(workState.reservedRide?.id, reservedRideId);
        expect(workState.reservedRide?.pickupLatitude, _pickupLatitude + 0.001);
        expect(
          workState.reservedRide?.pickupLongitude,
          _pickupLongitude + 0.001,
        );
        expect(workState.reservedRide?.dispatchRound, 2);
        expect(workState.reservedRide?.driverBonusMinor, 500);

        final completedRide = await lifecycle.completeRide(
          rideId: currentRideId,
          driverId: driverId,
          meterFareMinor: 1200,
        );
        expect(completedRide.status, RideRequestStatus.completed);
        expect(completedRide.pickupLatitude, _pickupLatitude);
        expect(completedRide.pickupLongitude, _pickupLongitude);
        final reloadedCompletedRide = await rideRepository.findById(
          currentRideId,
        );
        expect(reloadedCompletedRide?.pickupLatitude, _pickupLatitude);
        expect(reloadedCompletedRide?.pickupLongitude, _pickupLongitude);

        workState = await workStateRepository.loadByDriverId(driverId);
        expect(workState.currentRide?.id, reservedRideId);
        expect(workState.currentRide?.pickupLatitude, _pickupLatitude + 0.001);
        expect(
          workState.currentRide?.pickupLongitude,
          _pickupLongitude + 0.001,
        );
        expect(workState.currentRide?.dispatchRound, 2);
        expect(workState.currentRide?.driverBonusMinor, 500);
        expect(workState.reservedRide, isNull);

        await lifecycle.markDriverArriving(
          rideId: reservedRideId,
          driverId: driverId,
        );
        final promotedRideInProgress = await lifecycle.startRide(
          rideId: reservedRideId,
          driverId: driverId,
        );
        expect(promotedRideInProgress.pickupLatitude, _pickupLatitude + 0.001);
        expect(
          promotedRideInProgress.pickupLongitude,
          _pickupLongitude + 0.001,
        );

        final completedReservedRide = await lifecycle.completeRide(
          rideId: reservedRideId,
          driverId: driverId,
          meterFareMinor: 1500,
        );
        expect(completedReservedRide.status, RideRequestStatus.completed);
        expect(completedReservedRide.pickupLatitude, _pickupLatitude + 0.001);
        expect(completedReservedRide.pickupLongitude, _pickupLongitude + 0.001);

        final reloadedLegacyRide = await rideRepository.findById(legacyRideId);
        expect(reloadedLegacyRide, isNotNull);
        expect(reloadedLegacyRide!.pickupLatitude, isNull);
        expect(reloadedLegacyRide.pickupLongitude, isNull);
        final finalBoardRides = await waitingBoard.findOldestPage(
          notBefore: requestedAt.subtract(const Duration(seconds: 1)),
          limit: 200,
        );
        final finalBoardById = {
          for (final ride in finalBoardRides) ride.id: ride,
        };
        expect(finalBoardById[legacyRideId]?.pickupLatitude, isNull);
        expect(finalBoardById[legacyRideId]?.pickupLongitude, isNull);
      } finally {
        try {
          await db.execute(
            Sql.named('DELETE FROM ride_reservations WHERE id = @id'),
            parameters: {'id': reservationId},
          );
          await db.execute(
            Sql.named('DELETE FROM rides WHERE id = ANY(@rideIds)'),
            parameters: {'rideIds': rideIds},
          );
          await db.execute(
            Sql.named('DELETE FROM driver_queue_states WHERE shift_id = @id'),
            parameters: {'id': shiftId},
          );
          await db.execute(
            Sql.named('DELETE FROM driver_shifts WHERE id = @id'),
            parameters: {'id': shiftId},
          );
          await db.execute(
            Sql.named('DELETE FROM vehicles WHERE id = @id'),
            parameters: {'id': vehicleId},
          );
          await db.execute(
            Sql.named('DELETE FROM drivers WHERE id = @id'),
            parameters: {'id': driverId},
          );
        } finally {
          await db.close();
        }
      }
    },
  );
}

import 'dart:io';

import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
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

  const rideId = 'postgres-repository-check';
  const driverId = 'driver-check';
  const vehicleId = 'vehicle-check';

  try {
    await _cleanup(connection, rideId: rideId);

    final repository = PostgresRideRequestRepository(database: connection);

    // ============================================================
    // ROUND 2 / +5 EUR BONUS
    // ============================================================

    final originalRide = RideRequest(
      id: rideId,
      pickup: 'Test pickup',
      destination: 'Test destination',
      passengers: 2,
      hasLuggage: true,
      requestedAt: DateTime.now().toUtc(),
      status: RideRequestStatus.waitingForVehicle,
      dispatchRound: RideRequest.bonusDispatchRound,
      driverBonusMinor: RideRequest.driverBonusFiveEuroMinor,
      bonusDecision: RideBonusDecision.accepted,
    );

    await repository.save(originalRide);

    print('round 2 ride save: OK');

    // ============================================================
    // READ BACK
    // ============================================================

    final savedRide = await repository.findById(rideId);

    if (savedRide == null) {
      throw StateError('Saved ride was not found.');
    }

    if (savedRide.id != rideId ||
        savedRide.pickup != 'Test pickup' ||
        savedRide.destination != 'Test destination' ||
        savedRide.passengers != 2 ||
        savedRide.hasLuggage != true ||
        savedRide.status != RideRequestStatus.waitingForVehicle ||
        savedRide.currency != 'EUR') {
      throw StateError('Saved ride data does not match.');
    }

    if (savedRide.dispatchRound != RideRequest.bonusDispatchRound ||
        savedRide.driverBonusMinor != RideRequest.driverBonusFiveEuroMinor ||
        savedRide.bonusDecision != RideBonusDecision.accepted) {
      throw StateError('Round 2 bonus state was not restored correctly.');
    }

    print('findById: OK');
    print('round 2 / +500 / accepted restored: OK');

    // ============================================================
    // UPSERT
    // ============================================================

    final updatedWaitingRide = savedRide.copyWith(
      pickup: 'Updated test pickup',
    );

    await repository.save(updatedWaitingRide);

    final updatedRide = await repository.findById(rideId);

    if (updatedRide == null) {
      throw StateError('Updated ride was not found.');
    }

    if (updatedRide.pickup != 'Updated test pickup') {
      throw StateError('Ride upsert did not persist the updated pickup.');
    }

    if (updatedRide.dispatchRound != RideRequest.bonusDispatchRound ||
        updatedRide.driverBonusMinor != RideRequest.driverBonusFiveEuroMinor ||
        updatedRide.bonusDecision != RideBonusDecision.accepted) {
      throw StateError('Upsert changed round 2 bonus state.');
    }

    print('update/upsert: OK');
    print('upsert preserved bonus state: OK');

    // ============================================================
    // MANUAL CLAIM FROM GENERAL BOARD
    // ============================================================

    final claimedRide = await repository.claimWaitingRide(
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      targetStatus: RideRequestStatus.accepted,
    );

    if (claimedRide == null) {
      throw StateError('Waiting ride could not be claimed.');
    }

    if (claimedRide.status != RideRequestStatus.accepted ||
        claimedRide.assignedDriverId != driverId ||
        claimedRide.assignedVehicleId != vehicleId) {
      throw StateError('Claimed ride assignment does not match.');
    }

    if (claimedRide.dispatchRound != RideRequest.bonusDispatchRound ||
        claimedRide.driverBonusMinor != RideRequest.driverBonusFiveEuroMinor ||
        claimedRide.bonusDecision != RideBonusDecision.accepted) {
      throw StateError('Manual claim lost the round 2 bonus state.');
    }

    print('manual claim: OK');
    print('manual claim preserved +5 EUR bonus: OK');

    // ============================================================
    // FIND BY ASSIGNED DRIVER
    // ============================================================

    final driverRides = await repository.findByAssignedDriverId(driverId);

    RideRequest? matchingRide;

    for (final ride in driverRides) {
      if (ride.id == rideId) {
        matchingRide = ride;
        break;
      }
    }

    if (matchingRide == null) {
      throw StateError('Ride was not found by assigned driver.');
    }

    if (matchingRide.status != RideRequestStatus.accepted ||
        matchingRide.assignedDriverId != driverId ||
        matchingRide.assignedVehicleId != vehicleId) {
      throw StateError('Assigned ride data does not match.');
    }

    if (matchingRide.dispatchRound != RideRequest.bonusDispatchRound ||
        matchingRide.driverBonusMinor != RideRequest.driverBonusFiveEuroMinor ||
        matchingRide.bonusDecision != RideBonusDecision.accepted) {
      throw StateError('Assigned driver query lost the bonus state.');
    }

    print('findByAssignedDriverId: OK');
    print('assigned driver query preserved bonus state: OK');

    print('');
    print('PostgreSQL repository check OK');
  } finally {
    await _cleanup(connection, rideId: rideId);

    await connection.close();
  }
}

Future<void> _cleanup(Session database, {required String rideId}) async {
  await database.execute(
    Sql.named('DELETE FROM rides WHERE id = @id'),
    parameters: {'id': rideId},
  );
}

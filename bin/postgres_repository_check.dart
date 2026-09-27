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

  try {
    await connection.execute(
      Sql.named('DELETE FROM rides WHERE id = @id'),
      parameters: {'id': rideId},
    );

    final repository = PostgresRideRequestRepository(database: connection);

    final originalRide = RideRequest(
      id: rideId,
      pickup: 'Test pickup',
      destination: 'Test destination',
      passengers: 2,
      hasLuggage: true,
      requestedAt: DateTime.now().toUtc(),
      status: RideRequestStatus.waitingForVehicle,
    );

    await repository.save(originalRide);

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

    final assignedRide = savedRide
        .transitionTo(RideRequestStatus.accepted)
        .copyWith(
          assignedDriverId: 'driver-check',
          assignedVehicleId: 'vehicle-check',
        );

    await repository.save(assignedRide);

    final driverRides = await repository.findByAssignedDriverId('driver-check');

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
        matchingRide.assignedDriverId != 'driver-check' ||
        matchingRide.assignedVehicleId != 'vehicle-check') {
      throw StateError('Updated ride data does not match.');
    }

    print('PostgreSQL repository check OK');
    print('save: OK');
    print('findById: OK');
    print('update/upsert: OK');
    print('findByAssignedDriverId: OK');
  } finally {
    await connection.execute(
      Sql.named('DELETE FROM rides WHERE id = @id'),
      parameters: {'id': rideId},
    );

    await connection.close();
  }
}

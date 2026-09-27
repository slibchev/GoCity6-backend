import 'dart:io';

import 'package:gocity6_backend/dispatch/postgres_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
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

  const rideId = 'ride-offer-repository-check';
  const driver1Id = 'driver-offer-check-1';
  const driver2Id = 'driver-offer-check-2';
  const vehicle1Id = 'vehicle-offer-check-1';
  const vehicle2Id = 'vehicle-offer-check-2';

  try {
    await _cleanup(connection);

    final createdAt = DateTime.now().toUtc();

    await connection.execute(
      Sql.named('''
        INSERT INTO drivers (
          id,
          username,
          password_hash,
          first_name,
          last_name,
          phone,
          is_active,
          created_at
        )
        VALUES (
          @id,
          @username,
          @passwordHash,
          @firstName,
          @lastName,
          @phone,
          TRUE,
          @createdAt
        )
      '''),
      parameters: {
        'id': driver1Id,
        'username': 'ride_offer_check_driver_1',
        'passwordHash': 'test-only-hash',
        'firstName': 'Test',
        'lastName': 'Driver One',
        'phone': 'test-phone-1',
        'createdAt': createdAt,
      },
    );

    await connection.execute(
      Sql.named('''
        INSERT INTO drivers (
          id,
          username,
          password_hash,
          first_name,
          last_name,
          phone,
          is_active,
          created_at
        )
        VALUES (
          @id,
          @username,
          @passwordHash,
          @firstName,
          @lastName,
          @phone,
          TRUE,
          @createdAt
        )
      '''),
      parameters: {
        'id': driver2Id,
        'username': 'ride_offer_check_driver_2',
        'passwordHash': 'test-only-hash',
        'firstName': 'Test',
        'lastName': 'Driver Two',
        'phone': 'test-phone-2',
        'createdAt': createdAt,
      },
    );

    await connection.execute(
      Sql.named('''
        INSERT INTO vehicles (
          id,
          plate_number,
          is_active,
          created_at
        )
        VALUES (
          @id,
          @plateNumber,
          TRUE,
          @createdAt
        )
      '''),
      parameters: {
        'id': vehicle1Id,
        'plateNumber': 'TEST-OFFER-1',
        'createdAt': createdAt,
      },
    );

    await connection.execute(
      Sql.named('''
        INSERT INTO vehicles (
          id,
          plate_number,
          is_active,
          created_at
        )
        VALUES (
          @id,
          @plateNumber,
          TRUE,
          @createdAt
        )
      '''),
      parameters: {
        'id': vehicle2Id,
        'plateNumber': 'TEST-OFFER-2',
        'createdAt': createdAt,
      },
    );

    await connection.execute(
      Sql.named('''
        INSERT INTO rides (
          id,
          pickup,
          destination,
          passengers,
          has_luggage,
          requested_at,
          status,
          currency
        )
        VALUES (
          @id,
          @pickup,
          @destination,
          1,
          FALSE,
          @requestedAt,
          'waitingForVehicle',
          'EUR'
        )
      '''),
      parameters: {
        'id': rideId,
        'pickup': 'Ride offer check pickup',
        'destination': 'Ride offer check destination',
        'requestedAt': createdAt,
      },
    );

    final repository = PostgresRideOfferRepository(database: connection);

    final firstOfferedAt = DateTime.now().toUtc();

    final firstOffer = RideOffer.create(
      id: 'offer-repository-check-1',
      rideId: rideId,
      driverId: driver1Id,
      vehicleId: vehicle1Id,
      etaSeconds: 300,
      distanceMeters: 700,
      offeredAt: firstOfferedAt,
      timeout: const Duration(seconds: 15),
    );

    await repository.create(firstOffer);

    final savedOffer = await repository.findById(firstOffer.id);

    if (savedOffer == null) {
      throw StateError('Created offer was not found.');
    }

    if (savedOffer.status != RideOfferStatus.pending ||
        savedOffer.rideId != rideId ||
        savedOffer.driverId != driver1Id ||
        savedOffer.vehicleId != vehicle1Id ||
        savedOffer.etaSeconds != 300 ||
        savedOffer.distanceMeters != 700) {
      throw StateError('Created offer data does not match.');
    }

    final rideOffers = await repository.findByRideId(rideId);

    if (rideOffers.length != 1 || rideOffers.first.id != firstOffer.id) {
      throw StateError('Ride offer history does not match.');
    }

    final rejectedAt = firstOfferedAt.add(const Duration(seconds: 5));

    final rejectedOffer = firstOffer.reject(rejectedAt);

    final firstResolveSucceeded = await repository.resolve(rejectedOffer);

    if (!firstResolveSucceeded) {
      throw StateError('First resolve should succeed.');
    }

    final secondResolveSucceeded = await repository.resolve(rejectedOffer);

    if (secondResolveSucceeded) {
      throw StateError('Second resolve should not succeed.');
    }

    final storedRejectedOffer = await repository.findById(firstOffer.id);

    if (storedRejectedOffer?.status != RideOfferStatus.rejected ||
        storedRejectedOffer?.resolvedAt != rejectedAt) {
      throw StateError('Rejected offer was not persisted correctly.');
    }

    final secondOfferedAt = DateTime.now().toUtc().subtract(
      const Duration(minutes: 1),
    );

    final secondOffer = RideOffer.create(
      id: 'offer-repository-check-2',
      rideId: rideId,
      driverId: driver2Id,
      vehicleId: vehicle2Id,
      etaSeconds: 360,
      distanceMeters: 900,
      offeredAt: secondOfferedAt,
      timeout: const Duration(seconds: 15),
    );

    await repository.create(secondOffer);

    final expiredPendingOffers = await repository.findPendingExpiredAt(
      DateTime.now().toUtc(),
    );

    final foundExpiredPendingOffer = expiredPendingOffers.any(
      (offer) => offer.id == secondOffer.id,
    );

    if (!foundExpiredPendingOffer) {
      throw StateError('Expired pending offer was not found.');
    }

    final expiredOffer = secondOffer.expire(DateTime.now().toUtc());

    final expireSucceeded = await repository.resolve(expiredOffer);

    if (!expireSucceeded) {
      throw StateError('Expiring pending offer should succeed.');
    }

    final finalHistory = await repository.findByRideId(rideId);

    if (finalHistory.length != 2) {
      throw StateError('Expected two persisted offers.');
    }

    print('PostgreSQL ride offer repository check OK');
    print('create: OK');
    print('findById: OK');
    print('findByRideId: OK');
    print('resolve: OK');
    print('double resolve protection: OK');
    print('findPendingExpiredAt: OK');
    print('expire: OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _cleanup(Session database) async {
  await database.execute(
    Sql.named('DELETE FROM ride_offers WHERE ride_id = @rideId'),
    parameters: {'rideId': 'ride-offer-repository-check'},
  );

  await database.execute(
    Sql.named('DELETE FROM rides WHERE id = @rideId'),
    parameters: {'rideId': 'ride-offer-repository-check'},
  );

  await database.execute(
    Sql.named('DELETE FROM drivers WHERE id = @driver1Id OR id = @driver2Id'),
    parameters: {
      'driver1Id': 'driver-offer-check-1',
      'driver2Id': 'driver-offer-check-2',
    },
  );

  await database.execute(
    Sql.named(
      'DELETE FROM vehicles WHERE id = @vehicle1Id OR id = @vehicle2Id',
    ),
    parameters: {
      'vehicle1Id': 'vehicle-offer-check-1',
      'vehicle2Id': 'vehicle-offer-check-2',
    },
  );
}

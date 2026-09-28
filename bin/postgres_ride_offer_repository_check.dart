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
  const driverId = 'driver-offer-check-1';
  const vehicleId = 'vehicle-offer-check-1';

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
        'id': driverId,
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
        'id': vehicleId,
        'plateNumber': 'TEST-OFFER-1',
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
          'pending',
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

    // ============================================================
    // ROUND 1 — БЕЗ БОНУС
    // ============================================================

    final firstOfferedAt = DateTime.now().toUtc().subtract(
      const Duration(minutes: 2),
    );

    final firstOffer = RideOffer.create(
      id: 'offer-repository-check-1',
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      etaSeconds: 300,
      distanceMeters: 700,
      dispatchRound: RideOffer.normalDispatchRound,
      bonusMinor: RideOffer.noBonusMinor,
      offeredAt: firstOfferedAt,
      timeout: const Duration(seconds: 15),
    );

    await repository.create(firstOffer);

    final savedFirstOffer = await repository.findById(firstOffer.id);

    if (savedFirstOffer == null) {
      throw StateError('Created round 1 offer was not found.');
    }

    if (savedFirstOffer.status != RideOfferStatus.pending ||
        savedFirstOffer.rideId != rideId ||
        savedFirstOffer.driverId != driverId ||
        savedFirstOffer.vehicleId != vehicleId ||
        savedFirstOffer.etaSeconds != 300 ||
        savedFirstOffer.distanceMeters != 700 ||
        savedFirstOffer.dispatchRound != RideOffer.normalDispatchRound ||
        savedFirstOffer.bonusMinor != RideOffer.noBonusMinor) {
      throw StateError('Round 1 offer data does not match.');
    }

    print('round 1 persisted with zero bonus: OK');

    final rejectedAt = firstOfferedAt.add(const Duration(seconds: 5));

    final rejectedOffer = firstOffer.reject(rejectedAt);

    final firstResolveSucceeded = await repository.resolve(rejectedOffer);

    if (!firstResolveSucceeded) {
      throw StateError('Round 1 reject should succeed.');
    }

    final secondResolveSucceeded = await repository.resolve(rejectedOffer);

    if (secondResolveSucceeded) {
      throw StateError('Second resolve should not succeed.');
    }

    final storedRejectedOffer = await repository.findById(firstOffer.id);

    if (storedRejectedOffer == null ||
        storedRejectedOffer.status != RideOfferStatus.rejected ||
        storedRejectedOffer.resolvedAt != rejectedAt ||
        storedRejectedOffer.dispatchRound != RideOffer.normalDispatchRound ||
        storedRejectedOffer.bonusMinor != RideOffer.noBonusMinor) {
      throw StateError('Rejected round 1 offer was not persisted correctly.');
    }

    print('round 1 values preserved after reject: OK');
    print('double resolve protection: OK');

    // ============================================================
    // ПРЕМИНАВАНЕ КЪМ ROUND 2 — +5 EUR
    // ============================================================

    await connection.execute(
      Sql.named('''
        UPDATE rides
        SET
          dispatch_round = 2,
          driver_bonus_minor = 500,
          bonus_decision = 'accepted'
        WHERE id = @rideId
      '''),
      parameters: {'rideId': rideId},
    );

    final secondOfferedAt = firstOfferedAt.add(const Duration(minutes: 1));

    // Нарочно използваме СЪЩИЯ driverId.
    // Това трябва да е позволено в round 2.
    final secondOffer = RideOffer.create(
      id: 'offer-repository-check-2',
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      etaSeconds: 360,
      distanceMeters: 900,
      dispatchRound: RideOffer.bonusDispatchRound,
      bonusMinor: RideOffer.shortRideBonusMinor,
      offeredAt: secondOfferedAt,
      timeout: const Duration(seconds: 15),
    );

    await repository.create(secondOffer);

    final savedSecondOffer = await repository.findById(secondOffer.id);

    if (savedSecondOffer == null) {
      throw StateError('Created round 2 offer was not found.');
    }

    if (savedSecondOffer.driverId != driverId ||
        savedSecondOffer.dispatchRound != RideOffer.bonusDispatchRound ||
        savedSecondOffer.bonusMinor != RideOffer.shortRideBonusMinor) {
      throw StateError('Round 2 bonus offer data does not match.');
    }

    print('same driver received same ride again in round 2: OK');
    print('round 2 persisted with 500 cent bonus: OK');

    final rideOffers = await repository.findByRideId(rideId);

    if (rideOffers.length != 2) {
      throw StateError('Expected two persisted ride offers.');
    }

    if (rideOffers[0].dispatchRound != RideOffer.normalDispatchRound ||
        rideOffers[0].bonusMinor != RideOffer.noBonusMinor ||
        rideOffers[1].dispatchRound != RideOffer.bonusDispatchRound ||
        rideOffers[1].bonusMinor != RideOffer.shortRideBonusMinor) {
      throw StateError('Ride offer history round/bonus data does not match.');
    }

    print('round-aware ride history: OK');

    final expiredPendingOffers = await repository.findPendingExpiredAt(
      DateTime.now().toUtc(),
    );

    final foundExpiredPendingOffer = expiredPendingOffers.any(
      (offer) =>
          offer.id == secondOffer.id &&
          offer.dispatchRound == RideOffer.bonusDispatchRound &&
          offer.bonusMinor == RideOffer.shortRideBonusMinor,
    );

    if (!foundExpiredPendingOffer) {
      throw StateError('Expired pending round 2 offer was not found.');
    }

    print('findPendingExpiredAt preserves bonus data: OK');

    final expiredOffer = secondOffer.expire(DateTime.now().toUtc());

    final expireSucceeded = await repository.resolve(expiredOffer);

    if (!expireSucceeded) {
      throw StateError('Expiring round 2 offer should succeed.');
    }

    final storedExpiredOffer = await repository.findById(secondOffer.id);

    if (storedExpiredOffer == null ||
        storedExpiredOffer.status != RideOfferStatus.expired ||
        storedExpiredOffer.dispatchRound != RideOffer.bonusDispatchRound ||
        storedExpiredOffer.bonusMinor != RideOffer.shortRideBonusMinor) {
      throw StateError('Round 2 values were not preserved after expire.');
    }

    print('round 2 values preserved after expire: OK');

    print('');
    print('PostgreSQL ride offer repository check OK');
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
    Sql.named('DELETE FROM drivers WHERE id = @driverId'),
    parameters: {'driverId': 'driver-offer-check-1'},
  );

  await database.execute(
    Sql.named('DELETE FROM vehicles WHERE id = @vehicleId'),
    parameters: {'vehicleId': 'vehicle-offer-check-1'},
  );
}

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:gocity6_backend/dispatch/postgres_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';

void main() {
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

  test('PostgreSQL ride offer display acknowledgement', () async {
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
    final rideId = uuid.v4();
    final driverId = uuid.v4();
    final vehicleId = uuid.v4();
    final offerId = uuid.v4();

    try {
      final dbName = await database.execute('SELECT current_database()');

      expect(dbName.first[0], 'city6_test');

      final repository = PostgresRideOfferRepository(database: database);

      final now = DateTime.now().toUtc();

      await database.execute(
        Sql.named('''
          INSERT INTO drivers (
            id, username, password_hash,
            first_name, last_name, phone, created_at
          )
          VALUES (
            @id, @username, 'test',
            'Test', 'Driver', '000', @now
          )
        '''),
        parameters: {'id': driverId, 'username': 'test-$driverId', 'now': now},
      );

      await database.execute(
        Sql.named('''
          INSERT INTO vehicles (
            id, plate_number, created_at
          )
          VALUES (@id, @plate, @now)
        '''),
        parameters: {'id': vehicleId, 'plate': 'TEST-$vehicleId', 'now': now},
      );

      await database.execute(
        Sql.named('''
          INSERT INTO rides (
            id, pickup, destination,
            passengers, requested_at, status
          )
          VALUES (
            @id, 'Test pickup', 'Test destination',
            2, @now, 'pending'
          )
        '''),
        parameters: {'id': rideId, 'now': now},
      );

      final offeredAt = now.subtract(const Duration(seconds: 2));

      final offer = RideOffer.create(
        id: offerId,
        rideId: rideId,
        driverId: driverId,
        vehicleId: vehicleId,
        etaSeconds: 120,
        distanceMeters: 1000,
        offeredAt: offeredAt,
        timeout: const Duration(seconds: 15),
      );

      await repository.create(offer);

      // Wrong driver must be rejected.
      final wrongDriver = await repository.markDisplayed(
        offerId: offerId,
        driverId: 'another-driver',
        displayedAt: now,
      );
      expect(wrongDriver, isFalse);

      // Correct driver succeeds.
      final firstAck = await repository.markDisplayed(
        offerId: offerId,
        driverId: driverId,
        displayedAt: now,
      );
      expect(firstAck, isTrue);

      // Duplicate must not overwrite original timestamp.
      final duplicateAck = await repository.markDisplayed(
        offerId: offerId,
        driverId: driverId,
        displayedAt: now.add(const Duration(seconds: 1)),
      );
      expect(duplicateAck, isFalse);

      final saved = await repository.findById(offerId);
      expect(saved, isNotNull);
      expect(saved!.displayedAt, now);

      // Prepare a second expired offer.
      await database.execute(
        Sql.named('''
          UPDATE ride_offers
          SET status = 'expired',
              resolved_at = expires_at
          WHERE id = @id
        '''),
        parameters: {'id': offerId},
      );

      final expiredOfferId = uuid.v4();
      final expiredAt = now.subtract(const Duration(seconds: 20));

      final expiredOffer = RideOffer.create(
        id: expiredOfferId,
        rideId: rideId,
        driverId: driverId,
        vehicleId: vehicleId,
        etaSeconds: 120,
        distanceMeters: 1000,
        offeredAt: expiredAt,
        timeout: const Duration(seconds: 15),
        dispatchRound: 2,
        bonusMinor: 500,
      );

      await repository.create(expiredOffer);

      final lateAck = await repository.markDisplayed(
        offerId: expiredOfferId,
        driverId: driverId,
        displayedAt: now,
      );

      expect(lateAck, isFalse);

      final lateSaved = await repository.findById(expiredOfferId);
      expect(lateSaved?.displayedAt, isNull);
    } finally {
      // Remove only records created by this test.
      try {
        await database.execute(
          Sql.named('DELETE FROM ride_offers WHERE ride_id = @id'),
          parameters: {'id': rideId},
        );
        await database.execute(
          Sql.named('DELETE FROM rides WHERE id = @id'),
          parameters: {'id': rideId},
        );
        await database.execute(
          Sql.named('DELETE FROM vehicles WHERE id = @id'),
          parameters: {'id': vehicleId},
        );
        await database.execute(
          Sql.named('DELETE FROM drivers WHERE id = @id'),
          parameters: {'id': driverId},
        );
      } finally {
        await database.close();
      }
    }
  });
}

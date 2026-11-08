import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/ride/ride_submission_payload.dart';

void main() {
  test('concurrent client requests create only one PostgreSQL ride', () async {
    final username = Platform.environment['CITY6_TEST_DB_USER'];
    if (username == null || username.isEmpty) {
      fail('CITY6_TEST_DB_USER is required for city6_test.');
    }
    final portValue = Platform.environment['CITY6_TEST_DB_PORT'];
    final port = portValue == null ? null : int.tryParse(portValue);
    if (port == null || port < 1 || port > 65535) {
      fail('CITY6_TEST_DB_PORT must be a valid PostgreSQL port.');
    }
    final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

    if (password == null || password.isEmpty) {
      fail('CITY6_TEST_DB_PASSWORD is required.');
    }

    Future<Connection> connect() => Connection.open(
      Endpoint(
        host: '127.0.0.1',
        port: port,
        database: 'city6_test',
        username: username,
        password: password,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    final firstDb = await connect();
    Connection? secondDb;

    final uuid = const Uuid();
    final clientId = uuid.v4();
    final firstId = uuid.v4();
    final secondId = uuid.v4();
    const pickupLatitude = 42.6977123;
    const pickupLongitude = 23.3219876;
    const destinationLatitude = 42.6501234;
    const destinationLongitude = 23.3805678;

    try {
      final identity = await firstDb.execute(
        'SELECT current_database(), current_user, inet_server_port()',
      );
      expect(identity.single[0], 'city6_test');
      expect(identity.single[1], username);
      expect(identity.single[2], port);

      secondDb = await connect();

      final firstRepository = PostgresRideRequestRepository(database: firstDb);
      final secondRepository = PostgresRideRequestRepository(
        database: secondDb,
      );

      RideRequest newRide(String id) => RideRequest(
        id: id,
        clientRequestId: clientId,
        pickup: 'Test pickup',
        pickupLatitude: pickupLatitude,
        pickupLongitude: pickupLongitude,
        destination: 'Test destination',
        destinationLatitude: destinationLatitude,
        destinationLongitude: destinationLongitude,
        passengers: 2,
        requestedAt: DateTime.now().toUtc(),
      );

      Future<bool> tryInsert(
        PostgresRideRequestRepository repository,
        String id,
      ) async {
        try {
          await repository.save(newRide(id));
          return true;
        } on UniqueViolationException catch (error) {
          expect(error.constraintName, 'rides_client_request_id_unique_idx');
          return false;
        }
      }

      final results = await Future.wait([
        tryInsert(firstRepository, firstId),
        tryInsert(secondRepository, secondId),
      ]);

      expect(results.where((success) => success).length, 1);

      final existing = await firstRepository.findByClientRequestId(clientId);

      expect(existing, isNotNull);
      expect(existing!.clientRequestId, clientId);
      expect(existing.pickupLatitude, pickupLatitude);
      expect(existing.pickupLongitude, pickupLongitude);
      expect(existing.destinationLatitude, destinationLatitude);
      expect(existing.destinationLongitude, destinationLongitude);
      expect(
        rideSubmissionMatchesExisting(
          existing: existing,
          pickup: 'Test pickup',
          destination: 'Test destination',
          passengers: 2,
          hasLuggage: false,
          pickupLatitude: pickupLatitude,
          pickupLongitude: pickupLongitude,
          destinationLatitude: destinationLatitude,
          destinationLongitude: destinationLongitude,
        ),
        isTrue,
      );
      expect(
        rideSubmissionMatchesExisting(
          existing: existing,
          pickup: 'Test pickup',
          destination: 'Test destination',
          passengers: 2,
          hasLuggage: false,
          pickupLatitude: pickupLatitude,
          pickupLongitude: pickupLongitude + 0.001,
          destinationLatitude: destinationLatitude,
          destinationLongitude: destinationLongitude,
        ),
        isFalse,
      );
      expect(
        rideSubmissionMatchesExisting(
          existing: existing,
          pickup: 'Test pickup',
          destination: 'Test destination',
          passengers: 2,
          hasLuggage: false,
          pickupLatitude: pickupLatitude,
          pickupLongitude: pickupLongitude,
          destinationLatitude: destinationLatitude + 0.001,
          destinationLongitude: destinationLongitude,
        ),
        isFalse,
      );

      final updated = existing.transitionTo(
        RideRequestStatus.waitingForVehicle,
      );

      await firstRepository.save(updated);

      final reloaded = await secondRepository.findById(existing.id);
      expect(reloaded?.clientRequestId, clientId);
      expect(reloaded?.status, RideRequestStatus.waitingForVehicle);
      expect(reloaded?.pickupLatitude, pickupLatitude);
      expect(reloaded?.pickupLongitude, pickupLongitude);
      expect(reloaded?.destinationLatitude, destinationLatitude);
      expect(reloaded?.destinationLongitude, destinationLongitude);

      final count = await firstDb.execute(
        Sql.named('''
          SELECT COUNT(*)
          FROM rides
          WHERE client_request_id = @clientId
        '''),
        parameters: {'clientId': clientId},
      );

      expect(count.single[0], 1);
    } finally {
      try {
        await firstDb.execute(
          Sql.named('''
            DELETE FROM rides
            WHERE id IN (@firstId, @secondId)
          '''),
          parameters: {'firstId': firstId, 'secondId': secondId},
        );
      } finally {
        await secondDb?.close();
        await firstDb.close();
      }
    }
  });
}

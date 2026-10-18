import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';

void main() {
  test('concurrent client requests create only one PostgreSQL ride', () async {
    final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

    if (password == null || password.isEmpty) {
      fail('CITY6_TEST_DB_PASSWORD is required.');
    }

    Future<Connection> connect() => Connection.open(
      Endpoint(
        host: 'localhost',
        database: 'city6_test',
        username: 'city6_app',
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

    try {
      final databaseName = await firstDb.execute('SELECT current_database()');
      expect(databaseName.single[0], 'city6_test');

      secondDb = await connect();

      final firstRepository = PostgresRideRequestRepository(database: firstDb);
      final secondRepository = PostgresRideRequestRepository(
        database: secondDb,
      );

      RideRequest newRide(String id) => RideRequest(
        id: id,
        clientRequestId: clientId,
        pickup: 'Test pickup',
        destination: 'Test destination',
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

      final updated = existing.transitionTo(
        RideRequestStatus.waitingForVehicle,
      );

      await firstRepository.save(updated);

      final reloaded = await secondRepository.findById(existing.id);
      expect(reloaded?.clientRequestId, clientId);
      expect(reloaded?.status, RideRequestStatus.waitingForVehicle);

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

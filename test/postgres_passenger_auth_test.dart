import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/auth/passenger_authentication_service.dart';
import 'package:gocity6_backend/auth/passenger_ride_access_policy.dart';
import 'package:gocity6_backend/auth/postgres_passenger_auth_repository.dart';
import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';

void main() {
  final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  final fixtureSuffix = const Uuid().v4();
  final passengerOneId = const Uuid().v4();
  final passengerTwoId = const Uuid().v4();
  final rideOneId = const Uuid().v4();
  final rideTwoId = const Uuid().v4();
  final usernameOne = 'passenger-auth-$fixtureSuffix-1';
  final usernameTwo = 'passenger-auth-$fixtureSuffix-2';

  Connection? database;

  Future<Connection> openDatabase() {
    final dbPassword = password;
    if (dbPassword == null || dbPassword.isEmpty) {
      throw StateError('CITY6_TEST_DB_PASSWORD is required.');
    }
    return Connection.open(
      Endpoint(
        host: 'localhost',
        port: 5432,
        database: 'city6_test',
        username: 'city6_app',
        password: dbPassword,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  }

  setUpAll(() async {
    final dbPassword = password;
    if (dbPassword == null || dbPassword.isEmpty) {
      return;
    }
    database = await openDatabase();
    final identity = await database!.execute(
      'SELECT current_database(), current_user, current_schema(), '
      'host(inet_server_addr()), inet_server_port()',
    );
    expect(identity.single[0], 'city6_test');
    expect(identity.single[1], 'city6_app');
    expect(identity.single[2], 'public');
    expect(['127.0.0.1', '::1'], contains(identity.single[3]));
    expect(identity.single[4], 5432);

    final schema = await database!.execute(
      "SELECT to_regclass('public.passengers'), "
      "EXISTS (SELECT 1 FROM information_schema.columns "
      "WHERE table_schema = 'public' AND table_name = 'rides' "
      "AND column_name = 'passenger_id')",
    );
    expect(
      schema.single[0],
      isNotNull,
      reason: 'Migration 020 must be applied.',
    );
    expect(schema.single[1], isTrue, reason: 'rides.passenger_id must exist.');
  });

  tearDownAll(() async {
    final db = database;
    if (db == null) {
      return;
    }
    try {
      await db.execute(
        Sql.named('DELETE FROM rides WHERE id IN (@rideOneId, @rideTwoId)'),
        parameters: {'rideOneId': rideOneId, 'rideTwoId': rideTwoId},
      );
      await db.execute(
        Sql.named('''
          DELETE FROM passengers
          WHERE id IN (@passengerOneId, @passengerTwoId)
        '''),
        parameters: {
          'passengerOneId': passengerOneId,
          'passengerTwoId': passengerTwoId,
        },
      );
      final residue = await db.execute(
        Sql.named('''
          SELECT
            (SELECT count(*) FROM passengers
             WHERE id IN (@passengerOneId, @passengerTwoId))
            +
            (SELECT count(*) FROM rides
             WHERE id IN (@rideOneId, @rideTwoId))
        '''),
        parameters: {
          'passengerOneId': passengerOneId,
          'passengerTwoId': passengerTwoId,
          'rideOneId': rideOneId,
          'rideTwoId': rideTwoId,
        },
      );
      expect(residue.single[0], 0, reason: 'Passenger test fixtures remained.');
    } finally {
      await db.close();
    }
  });

  test(
    'Passenger identities, passwords, ride ownership, and persistence survive reconnect',
    () async {
      final db = database;
      if (db == null) {
        markTestSkipped('CITY6_TEST_DB_PASSWORD is required for city6_test.');
      }

      final now = DateTime.now().toUtc();
      await db!.execute(
        Sql.named('''
          INSERT INTO passengers (id, username, password_hash, status)
          VALUES
            (@passengerOneId, @usernameOne, @hashOne, 'active'),
            (@passengerTwoId, @usernameTwo, @hashTwo, 'active')
        '''),
        parameters: {
          'passengerOneId': passengerOneId,
          'usernameOne': usernameOne,
          'hashOne': BCrypt.hashpw('test-password-one', BCrypt.gensalt()),
          'passengerTwoId': passengerTwoId,
          'usernameTwo': usernameTwo,
          'hashTwo': BCrypt.hashpw('test-password-two', BCrypt.gensalt()),
        },
      );

      final rideRepository = PostgresRideRequestRepository(database: db);
      await rideRepository.save(
        RideRequest(
          id: rideOneId,
          passengerId: passengerOneId,
          pickup: 'Integration fixture pickup',
          destination: 'Integration fixture destination',
          passengers: 1,
          requestedAt: now,
        ),
      );
      await rideRepository.save(
        RideRequest(
          id: rideTwoId,
          passengerId: passengerTwoId,
          pickup: 'Integration fixture pickup',
          destination: 'Integration fixture destination',
          passengers: 1,
          requestedAt: now,
        ),
      );

      final firstRide = await rideRepository.findById(rideOneId);
      expect(firstRide?.passengerId, passengerOneId);
      expect(
        passengerRideAccess(
          ridePassengerId: firstRide?.passengerId,
          authenticatedPassengerId: passengerOneId,
        ),
        PassengerRideAccess.allowed,
      );
      expect(
        passengerRideAccess(
          ridePassengerId: firstRide?.passengerId,
          authenticatedPassengerId: passengerTwoId,
        ),
        PassengerRideAccess.notFound,
      );

      await db.close();
      database = await openDatabase();
      final reopenedRepository = PostgresPassengerAuthRepository(
        database: database!,
      );
      final auth = PassengerAuthenticationService(
        repository: reopenedRepository,
      );
      final authenticatedOne = await auth.authenticate(
        username: usernameOne,
        password: 'test-password-one',
      );
      final authenticatedTwo = await auth.authenticate(
        username: usernameTwo,
        password: 'test-password-two',
      );
      final wrongPassword = await auth.authenticate(
        username: usernameOne,
        password: 'wrong-password',
      );

      expect(authenticatedOne?.id, passengerOneId);
      expect(authenticatedTwo?.id, passengerTwoId);
      expect(wrongPassword, isNull);
      expect(await reopenedRepository.findById(passengerOneId), isNotNull);

      final rideAfterReconnect = await PostgresRideRequestRepository(
        database: database!,
      ).findById(rideOneId);
      expect(rideAfterReconnect?.passengerId, passengerOneId);
    },
    skip: password == null || password.isEmpty
        ? 'CITY6_TEST_DB_PASSWORD is required for city6_test.'
        : false,
  );
}

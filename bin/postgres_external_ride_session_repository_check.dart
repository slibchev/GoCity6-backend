import 'dart:io';

import 'package:gocity6_backend/dispatch/external_ride_session.dart';
import 'package:gocity6_backend/dispatch/external_ride_session_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_external_ride_session_repository.dart';
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

  final repository = PostgresExternalRideSessionRepository(
    database: connection,
  );

  const driverId = 'driver-external-ride-check';
  const sessionId = 'external-ride-check-001';

  try {
    await _cleanup(connection);

    await _createDriver(connection, driverId: driverId);

    final startedAt = DateTime.now().toUtc();

    final session = ExternalRideSession.create(
      id: sessionId,
      driverId: driverId,
      startedAt: startedAt,
    );

    final created = await repository.createActive(session);

    if (!created.isActive ||
        created.distanceMeters != 0 ||
        created.qualifiesAsExternalRide) {
      throw StateError('Created external ride session is invalid.');
    }

    print('create active external ride: OK');
    print('starts at zero meters: OK');

    final foundById = await repository.findById(sessionId);

    if (foundById == null ||
        foundById.id != sessionId ||
        foundById.driverId != driverId) {
      throw StateError('findById did not restore the session correctly.');
    }

    print('findById: OK');

    final active = await repository.findActiveByDriverId(driverId);

    if (active == null || active.id != sessionId) {
      throw StateError('findActiveByDriverId failed.');
    }

    print('findActiveByDriverId: OK');

    final afterFirstSegment = await repository.addVerifiedDistance(
      driverId: driverId,
      segmentDistanceMeters: 300,
    );

    if (afterFirstSegment.distanceMeters != 300 ||
        afterFirstSegment.qualifiesAsExternalRide) {
      throw StateError('First verified distance was not stored correctly.');
    }

    print('verified distance +300 m: OK');

    final afterSecondSegment = await repository.addVerifiedDistance(
      driverId: driverId,
      segmentDistanceMeters: 199,
    );

    if (afterSecondSegment.distanceMeters != 499 ||
        afterSecondSegment.qualifiesAsExternalRide ||
        afterSecondSegment.remainingMetersToQualify != 1) {
      throw StateError('499 meter threshold state is incorrect.');
    }

    print('499 m does not qualify: OK');

    final qualified = await repository.addVerifiedDistance(
      driverId: driverId,
      segmentDistanceMeters: 1,
    );

    if (qualified.distanceMeters != 500 ||
        !qualified.qualifiesAsExternalRide ||
        qualified.remainingMetersToQualify != 0) {
      throw StateError('500 meter qualification state is incorrect.');
    }

    print('500 m qualifies as external ride: OK');

    await _expectConflict(
      () => repository.createActive(
        ExternalRideSession.create(
          id: 'external-ride-check-duplicate',
          driverId: driverId,
          startedAt: startedAt.add(const Duration(minutes: 1)),
        ),
      ),
      ExternalRideSessionRepositoryConflict.driverAlreadyHasActiveSession,
    );

    print('second active session blocked: OK');

    final finishedAt = startedAt.add(const Duration(minutes: 15));

    final finished = await repository.finishActive(
      driverId: driverId,
      finishedAt: finishedAt,
    );

    if (finished.isActive ||
        finished.endedAt != finishedAt ||
        finished.distanceMeters != 500 ||
        !finished.qualifiesAsExternalRide) {
      throw StateError('Finished external ride session is invalid.');
    }

    print('finish active external ride: OK');
    print('500 m preserved after finish: OK');

    final activeAfterFinish = await repository.findActiveByDriverId(driverId);

    if (activeAfterFinish != null) {
      throw StateError('Finished session is still reported as active.');
    }

    print('no active session after finish: OK');

    await _expectConflict(
      () => repository.addVerifiedDistance(
        driverId: driverId,
        segmentDistanceMeters: 100,
      ),
      ExternalRideSessionRepositoryConflict.activeSessionNotFound,
    );

    print('distance update after finish blocked: OK');

    await _expectConflict(
      () => repository.finishActive(
        driverId: driverId,
        finishedAt: finishedAt.add(const Duration(minutes: 1)),
      ),
      ExternalRideSessionRepositoryConflict.activeSessionNotFound,
    );

    print('second finish blocked: OK');

    print('');
    print('PostgreSQL external ride session repository check OK');
  } finally {
    await _cleanup(connection);
    await connection.close();
  }
}

Future<void> _createDriver(Session database, {required String driverId}) async {
  await database.execute(
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
        'test-only-hash',
        'External',
        'Ride',
        @phone,
        TRUE,
        @createdAt
      )
    '''),
    parameters: {
      'id': driverId,
      'username': 'external_ride_check_driver',
      'phone': 'external-ride-check-phone',
      'createdAt': DateTime.now().toUtc(),
    },
  );
}

Future<void> _expectConflict(
  Future<void> Function() operation,
  ExternalRideSessionRepositoryConflict expected,
) async {
  try {
    await operation();
  } on ExternalRideSessionRepositoryConflictException catch (error) {
    if (error.conflict != expected) {
      throw StateError(
        'Expected ${expected.name}, '
        'got ${error.conflict.name}.',
      );
    }

    return;
  }

  throw StateError('Expected conflict ${expected.name}.');
}

Future<void> _cleanup(Session database) async {
  await database.execute('''
      DELETE FROM external_ride_sessions
      WHERE driver_id = 'driver-external-ride-check'
    ''');

  await database.execute('''
      DELETE FROM drivers
      WHERE id = 'driver-external-ride-check'
    ''');
}

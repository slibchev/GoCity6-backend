import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/auth/driver_token_service.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_shift_repository.dart';

void main() {
  const port = '8082';
  const host = 'http://127.0.0.1:$port';
  const jwtSecret = 'city6-http-integration-test-only-secret';

  late Connection db;
  Process? serverProcess;
  final driverId = const Uuid().v4();
  final vehicleId = const Uuid().v4();
  final shiftId = const Uuid().v4();
  final username = 'http-test-$driverId';

  setUpAll(() async {
    final password = Platform.environment['CITY6_TEST_DB_PASSWORD'];

    if (password == null || password.isEmpty) {
      fail('CITY6_TEST_DB_PASSWORD is required.');
    }

    db = await Connection.open(
      Endpoint(
        host: 'localhost',
        port: 5432,
        database: 'city6_test',
        username: 'city6_app',
        password: password,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    final result = await db.execute('SELECT current_database()');

    expect(result.single[0], 'city6_test');

    final now = DateTime.now().toUtc();

    await db.execute(
      Sql.named('''
        INSERT INTO drivers (
          id, username, password_hash,
          first_name, last_name, phone, created_at
        )
        VALUES (
          @id, @username, 'test',
          'HTTP', 'Test Driver', '000', @now
        )
      '''),
      parameters: {'id': driverId, 'username': username, 'now': now},
    );

    await db.execute(
      Sql.named('''
        INSERT INTO vehicles (
          id, plate_number, created_at
        )
        VALUES (@id, @plate, @now)
      '''),
      parameters: {'id': vehicleId, 'plate': 'TEST-$vehicleId', 'now': now},
    );

    final shiftRepository = PostgresDriverShiftRepository(database: db);

    await shiftRepository.startShift(
      shiftId: shiftId,
      driverId: driverId,
      vehicleId: vehicleId,
      startedAt: now,
    );

    serverProcess = await Process.start(
      'dart',
      ['run', 'bin/server.dart'],
      environment: {
        'PORT': port,
        'GOOGLE_MAPS_API_KEY': 'test-api-key',
        'CITY6_RIDE_STORAGE': 'postgres',
        'CITY6_DB_NAME': 'city6_test',
        'CITY6_DB_PASSWORD': password,
        'CITY6_DRIVER_JWT_SECRET': jwtSecret,
      },
    );

    await serverProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.contains('Server listening on port'))
        .timeout(const Duration(seconds: 30));
  });

  tearDownAll(() async {
    try {
      final process = serverProcess;

      if (process != null) {
        process.kill();
        await process.exitCode;
      }

      await db.execute(
        Sql.named('''
          DELETE FROM driver_queue_states
          WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftId},
      );

      await db.execute(
        Sql.named('''
          DELETE FROM driver_shifts
          WHERE id = @shiftId
        '''),
        parameters: {'shiftId': shiftId},
      );

      await db.execute(
        Sql.named('''
          DELETE FROM vehicles
          WHERE id = @vehicleId
        '''),
        parameters: {'vehicleId': vehicleId},
      );

      await db.execute(
        Sql.named('''
          DELETE FROM driver_dispatch_states
          WHERE driver_id = @driverId
        '''),
        parameters: {'driverId': driverId},
      );

      await db.execute(
        Sql.named('''
          DELETE FROM drivers
          WHERE id = @driverId
        '''),
        parameters: {'driverId': driverId},
      );
    } finally {
      await db.close();
    }
  });

  test('concurrent HTTP ride submissions are idempotent', () async {
    final clientId = const Uuid().v4();
    final url = Uri.parse('$host/rides');
    final headers = {'Content-Type': 'application/json'};

    final payload = {
      'clientRequestId': clientId,
      'pickup': 'Test Sofia Center',
      'destination': 'Test Sofia Airport',
      'passengers': 2,
      'hasLuggage': false,
    };

    try {
      final responses = await Future.wait([
        http.post(url, headers: headers, body: jsonEncode(payload)),
        http.post(url, headers: headers, body: jsonEncode(payload)),
      ]);

      for (final response in responses) {
        expect(response.statusCode, 201, reason: response.body);
      }

      final first = jsonDecode(responses[0].body) as Map<String, dynamic>;
      final second = jsonDecode(responses[1].body) as Map<String, dynamic>;

      expect(first['id'], isA<String>());
      expect(second['id'], first['id']);

      final count = await db.execute(
        Sql.named('''
          SELECT COUNT(*) FROM rides
          WHERE client_request_id = @clientId
        '''),
        parameters: {'clientId': clientId},
      );

      expect(count.single[0], 1);

      final conflict = await http.post(
        url,
        headers: headers,
        body: jsonEncode({...payload, 'destination': 'Different destination'}),
      );

      expect(conflict.statusCode, 409, reason: conflict.body);
    } finally {
      await db.execute(
        Sql.named('''
          DELETE FROM rides
          WHERE client_request_id = @clientId
        '''),
        parameters: {'clientId': clientId},
      );
    }
  });
  test('waiting rides API requires valid driver JWT', () async {
    final url = Uri.parse('$host/driver/rides/waiting');

    // Заявка без JWT трябва да бъде отказана.
    final unauthorizedResponse = await http.get(url);

    expect(unauthorizedResponse.statusCode, 401);

    // Генерираме валиден JWT за тестовия шофьор.
    final tokenService = DriverTokenService(secret: jwtSecret);

    final token = tokenService.createToken(
      driverId: driverId,
      username: username,
    );

    // Заявка с валиден JWT и активна смяна.
    final response = await http.get(
      url,
      headers: {'Authorization': 'Bearer $token'},
    );

    expect(response.statusCode, 200, reason: response.body);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['rides'], isA<List<dynamic>>());
    expect(response.headers['cache-control'], 'no-store');
  });

  test('authenticated driver selects waiting ride', () async {
    final rideId = const Uuid().v4();

    await db.execute(
      Sql.named('''
        INSERT INTO rides (
          id, pickup, destination,
          passengers, requested_at, status
        )
        VALUES (
          @rideId, 'HTTP test pickup', 'HTTP test destination',
          2, @now, 'waitingForVehicle'
        )
      '''),
      parameters: {'rideId': rideId, 'now': DateTime.now().toUtc()},
    );

    try {
      final url = Uri.parse('$host/rides/$rideId/select');

      final token = DriverTokenService(secret: jwtSecret)
          .createToken(driverId: driverId, username: username);

      // Умишлено подаваме грешни данни в тялото.
      // Backend трябва да използва JWT и активната смяна.
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'driverId': 'fake-driver',
          'vehicleId': 'fake-vehicle',
        }),
      );

      expect(response.statusCode, 200, reason: response.body);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      expect(body['id'], rideId);
      expect(body['status'], 'accepted');
      expect(body['assignedDriverId'], driverId);
      expect(body['assignedVehicleId'], vehicleId);

      final rows = await db.execute(
        Sql.named('''
          SELECT status, assigned_driver_id, assigned_vehicle_id
          FROM rides
          WHERE id = @rideId
        '''),
        parameters: {'rideId': rideId},
      );

      expect(rows, hasLength(1));

      final saved = rows.single.toColumnMap();

      expect(saved['status'], 'accepted');
      expect(saved['assigned_driver_id'], driverId);
      expect(saved['assigned_vehicle_id'], vehicleId);

      // Проверяваме, че приетата поръчка
      // вече не присъства в общия списък.
      final waitingResponse = await http.get(
        Uri.parse('$host/driver/rides/waiting'),
        headers: {'Authorization': 'Bearer $token'},
      );

      expect(waitingResponse.statusCode, 200);

      final waitingBody =
          jsonDecode(waitingResponse.body) as Map<String, dynamic>;

      final waitingRides = waitingBody['rides'] as List<dynamic>;

      expect(
        waitingRides.any(
          (ride) => (ride as Map<String, dynamic>)['id'] == rideId,
        ),
        isFalse,
      );
    } finally {
      await db.execute(
        Sql.named('DELETE FROM rides WHERE id = @rideId'),
        parameters: {'rideId': rideId},
      );

      await db.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET availability = 'available'
          WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftId},
      );
    }
  });

  test('ride selection rejects missing or invalid JWT', () async {
    final url = Uri.parse('$host/rides/nonexistent/select');

    // Опит за вземане на поръчка без JWT.
    final noTokenResponse = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({}),
    );

    expect(noTokenResponse.statusCode, 401);

    final noTokenBody =
        jsonDecode(noTokenResponse.body) as Map<String, dynamic>;

    expect(noTokenBody['error'], 'Authentication required.');

    // Опит с невалиден JWT.
    final invalidTokenResponse = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer invalid-test-token',
      },
      body: jsonEncode({}),
    );

    expect(invalidTokenResponse.statusCode, 401);

    final invalidTokenBody =
        jsonDecode(invalidTokenResponse.body) as Map<String, dynamic>;

    expect(invalidTokenBody['error'], 'Invalid or expired token.');
  });

  test('authenticated ride selection returns 404 for missing ride', () async {
    final missingRideId = const Uuid().v4();

    final token = DriverTokenService(secret: jwtSecret)
        .createToken(driverId: driverId, username: username);

    final response = await http.post(
      Uri.parse('$host/rides/$missingRideId/select'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({}),
    );

    expect(response.statusCode, 404, reason: response.body);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Ride not found.');
  });

  test('legacy ride promotion endpoint is unavailable', () async {
    final missingRideId = const Uuid().v4();

    final response = await http.post(
      Uri.parse('$host/rides/$missingRideId/promote'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': driverId}),
    );

    // Старият маршрут вече не трябва да съществува.
    expect(response.statusCode, 404);
  });

  test('authenticated driver completes full ride lifecycle', () async {
    final rideId = const Uuid().v4();

    await db.execute(
      Sql.named('''
        INSERT INTO rides (
          id, pickup, destination,
          passengers, requested_at, status
        )
        VALUES (
          @rideId, 'Lifecycle pickup', 'Lifecycle destination',
          2, @now, 'waitingForVehicle'
        )
      '''),
      parameters: {'rideId': rideId, 'now': DateTime.now().toUtc()},
    );

    try {
      final token = DriverTokenService(secret: jwtSecret)
          .createToken(driverId: driverId, username: username);

      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

      // Симулираме друг шофьор с валиден JWT.
      final otherDriverToken = DriverTokenService(
        secret: jwtSecret,
      ).createToken(driverId: const Uuid().v4(), username: 'other-test-driver');

      final otherDriverHeaders = {
        ...headers,
        'Authorization': 'Bearer $otherDriverToken',
      };

      Future<void> expectOtherDriverRejected(String action) async {
        final response = await http.post(
          Uri.parse('$host/driver/rides/$rideId/$action'),
          headers: otherDriverHeaders,
          body: action == 'complete'
              ? jsonEncode({'meterFareMinor': 1234})
              : null,
        );

        expect(response.statusCode, 409, reason: response.body);
      }

      // Невалидна сума на таксиметровия апарат.
      final invalidFareResponse = await http.post(
        Uri.parse('$host/driver/rides/$rideId/complete'),
        headers: headers,
        body: jsonEncode({'meterFareMinor': 0}),
      );

      expect(invalidFareResponse.statusCode, 400);
      expect(
        jsonDecode(invalidFareResponse.body)['error'],
        'meterFareMinor must be a positive integer.',
      );

      // Опит за приключване на несъществуваща поръчка.
      final missingRideId = const Uuid().v4();

      final missingRideResponse = await http.post(
        Uri.parse('$host/driver/rides/$missingRideId/complete'),
        headers: headers,
        body: jsonEncode({'meterFareMinor': 1234}),
      );

      expect(missingRideResponse.statusCode, 404);
      expect(jsonDecode(missingRideResponse.body)['error'], 'Ride not found.');

      // 1. Шофьорът приема поръчката.
      final selectResponse = await http.post(
        Uri.parse('$host/rides/$rideId/select'),
        headers: headers,
        body: jsonEncode({}),
      );

      expect(selectResponse.statusCode, 200, reason: selectResponse.body);

      final selected = jsonDecode(selectResponse.body) as Map<String, dynamic>;

      expect(selected['status'], 'accepted');
      expect(selected['assignedDriverId'], driverId);
      await expectOtherDriverRejected('arriving');

      // Старите маршрути без JWT трябва да са премахнати.
      for (final action in ['driver-arriving', 'start', 'complete']) {
        final legacyResponse = await http.post(
          Uri.parse('$host/rides/$rideId/$action'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'driverId': driverId, 'meterFareMinor': 1234}),
        );

        expect(
          legacyResponse.statusCode,
          404,
          reason: 'Legacy endpoint /rides/$rideId/$action is accessible.',
        );
      }

      // 2. Шофьорът пристига при клиента.
      final arrivingResponse = await http.post(
        Uri.parse('$host/driver/rides/$rideId/arriving'),
        headers: headers,
      );

      expect(arrivingResponse.statusCode, 200, reason: arrivingResponse.body);

      final arriving =
          jsonDecode(arrivingResponse.body) as Map<String, dynamic>;

      expect(arriving['status'], 'driverArriving');
      await expectOtherDriverRejected('start');

      // 3. Шофьорът започва курса.
      final startResponse = await http.post(
        Uri.parse('$host/driver/rides/$rideId/start'),
        headers: headers,
      );

      expect(startResponse.statusCode, 200, reason: startResponse.body);

      final started = jsonDecode(startResponse.body) as Map<String, dynamic>;

      expect(started['status'], 'inProgress');
      await expectOtherDriverRejected('complete');

      // 4. Шофьорът приключва курса.
      final completeResponse = await http.post(
        Uri.parse('$host/driver/rides/$rideId/complete'),
        headers: headers,
        body: jsonEncode({'meterFareMinor': 1234}),
      );

      expect(completeResponse.statusCode, 200, reason: completeResponse.body);

      final completed =
          jsonDecode(completeResponse.body) as Map<String, dynamic>;

      expect(completed['status'], 'completed');
      expect(completed['meterFareMinor'], 1234);
      expect(completed['commissionRateBps'], 1000);
      expect(completed['commissionAmountMinor'], 123);
      expect(completed['completedByDriverId'], driverId);
      expect(completed['currency'], 'EUR');
      expect(completed['completedAt'], isNotNull);

      // 5. Проверяваме реалния запис в PostgreSQL.
      final rideRows = await db.execute(
        Sql.named('''
          SELECT status, meter_fare_minor,
                 commission_amount_minor
          FROM rides
          WHERE id = @rideId
        '''),
        parameters: {'rideId': rideId},
      );

      expect(rideRows, hasLength(1));

      final saved = rideRows.single.toColumnMap();

      expect(saved['status'], 'completed');
      expect(saved['meter_fare_minor'], 1234);
      expect(saved['commission_amount_minor'], 123);

      // 6. След приключване шофьорът е свободен.
      final queueRows = await db.execute(
        Sql.named('''
          SELECT availability
          FROM driver_queue_states
          WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftId},
      );

      expect(queueRows, hasLength(1));
      expect(queueRows.single[0], 'available');
    } finally {
      // Почистваме тестовата поръчка.
      await db.execute(
        Sql.named('DELETE FROM rides WHERE id = @rideId'),
        parameters: {'rideId': rideId},
      );

      // Възстановяваме състоянието дори при грешка.
      await db.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET availability = 'available'
          WHERE shift_id = @shiftId
        '''),
        parameters: {'shiftId': shiftId},
      );
    }
  });
}

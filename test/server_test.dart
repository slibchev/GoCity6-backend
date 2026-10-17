import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:test/test.dart';

void main() {
  const port = '8081';
  const host = 'http://127.0.0.1:$port';

  late Process process;

  setUp(() async {
    process = await Process.start(
      'dart',
      ['run', 'bin/server.dart'],
      environment: {
        'PORT': port,
        'GOOGLE_MAPS_API_KEY': 'test-api-key',
        'CITY6_RIDE_STORAGE': 'memory',
      },
    );

    await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.contains('Server listening on port'));
  });

  tearDown(() async {
    process.kill();
    await process.exitCode;
  });

  test('Root returns backend status', () async {
    final response = await get(Uri.parse('$host/'));

    expect(response.statusCode, 200);
    expect(response.body, 'GoCity6 backend is running');
  });

  test('Route requires pickup and destination', () async {
    final response = await post(
      Uri.parse('$host/route'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({}),
    );

    expect(response.statusCode, 400);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Pickup and destination are required.');
  });

  test('Places autocomplete requires input', () async {
    final response = await post(
      Uri.parse('$host/places/autocomplete'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({}),
    );

    expect(response.statusCode, 400);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Input is required.');
  });

  test('Unknown route returns 404', () async {
    final response = await get(Uri.parse('$host/foobar'));

    expect(response.statusCode, 404);
  });
  test('POST rides creates waiting ride', () async {
    final response = await post(
      Uri.parse('$host/rides'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'pickup': 'Sofia Center',
        'destination': 'Sofia Airport',
        'passengers': 2,
        'hasLuggage': true,
      }),
    );

    expect(response.statusCode, 201);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['id'], isNotNull);
    expect(body['pickup'], 'Sofia Center');
    expect(body['destination'], 'Sofia Airport');
    expect(body['passengers'], 2);
    expect(body['hasLuggage'], isTrue);
    expect(body['status'], 'waitingForVehicle');
    expect(body['dispatchRound'], 1);
    expect(body['driverBonusMinor'], 0);
    expect(body['bonusDecision'], 'not_offered');
    expect(body['assignedDriverId'], isNull);
    expect(body['assignedVehicleId'], isNull);
    expect(body['requestedAt'], isNotNull);
    expect(body['currency'], 'EUR');
  });

  test('GET rides returns previously created ride', () async {
    final createResponse = await post(
      Uri.parse('$host/rides'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'pickup': 'Pickup address',
        'destination': 'Destination address',
        'passengers': 1,
      }),
    );

    expect(createResponse.statusCode, 201);

    final createdBody = jsonDecode(createResponse.body) as Map<String, dynamic>;

    final rideId = createdBody['id'] as String;

    final response = await get(Uri.parse('$host/rides/$rideId'));

    expect(response.statusCode, 200);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['id'], rideId);
    expect(body['pickup'], 'Pickup address');
    expect(body['destination'], 'Destination address');
    expect(body['passengers'], 1);
    expect(body['hasLuggage'], isFalse);
    expect(body['status'], 'waitingForVehicle');
  });

  test('GET rides returns 404 for missing ride', () async {
    final response = await get(Uri.parse('$host/rides/missing'));

    expect(response.statusCode, 404);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Ride not found.');
  });
  test(
    'POST ride bonus accept returns 503 when service is unavailable',
    () async {
      final response = await post(
        Uri.parse('$host/rides/ride-001/bonus/accept'),
      );

      expect(response.statusCode, 503);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      expect(body['error'], 'Customer bonus decision service is unavailable.');
    },
  );

  test(
    'POST ride bonus decline returns 503 when service is unavailable',
    () async {
      final response = await post(
        Uri.parse('$host/rides/ride-001/bonus/decline'),
      );

      expect(response.statusCode, 503);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      expect(body['error'], 'Customer bonus decision service is unavailable.');
    },
  );
  test('POST ride cancel cancels waiting ride', () async {
    final createResponse = await post(
      Uri.parse('$host/rides'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'pickup': 'Pickup address',
        'destination': 'Destination address',
        'passengers': 1,
      }),
    );

    expect(createResponse.statusCode, 201);

    final createdBody = jsonDecode(createResponse.body) as Map<String, dynamic>;

    final rideId = createdBody['id'] as String;

    final response = await post(Uri.parse('$host/rides/$rideId/cancel'));

    expect(response.statusCode, 200);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['id'], rideId);
    expect(body['status'], 'cancelled');
  });

  test('POST ride cancel returns 404 for missing ride', () async {
    final response = await post(Uri.parse('$host/rides/missing/cancel'));

    expect(response.statusCode, 404);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Ride not found.');
  });

  test(
    'POST ride cancel returns conflict when ride is already cancelled',
    () async {
      final createResponse = await post(
        Uri.parse('$host/rides'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'pickup': 'Pickup address',
          'destination': 'Destination address',
          'passengers': 1,
        }),
      );

      expect(createResponse.statusCode, 201);

      final createdBody =
          jsonDecode(createResponse.body) as Map<String, dynamic>;

      final rideId = createdBody['id'] as String;

      final firstCancelResponse = await post(
        Uri.parse('$host/rides/$rideId/cancel'),
      );

      expect(firstCancelResponse.statusCode, 200);

      final secondCancelResponse = await post(
        Uri.parse('$host/rides/$rideId/cancel'),
      );

      expect(secondCancelResponse.statusCode, 409);

      final body =
          jsonDecode(secondCancelResponse.body) as Map<String, dynamic>;

      expect(body['error'], 'Ride cannot be cancelled.');
    },
  );
  test('POST ride select requires configured driver authentication', () async {
    final createResponse = await post(
      Uri.parse('$host/rides'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'pickup': 'Pickup address',
        'destination': 'Destination address',
        'passengers': 1,
      }),
    );

    expect(createResponse.statusCode, 201);

    final createdBody = jsonDecode(createResponse.body) as Map<String, dynamic>;

    final rideId = createdBody['id'] as String;

    final response = await post(
      Uri.parse('$host/rides/$rideId/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({}),
    );

    expect(response.statusCode, 503);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Driver authentication unavailable.');
  });
  test('POST driver-arriving returns 404 for missing ride', () async {
    final response = await post(
      Uri.parse('$host/rides/missing/driver-arriving'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001'}),
    );

    expect(response.statusCode, 404);
  });
  test('POST start returns 404 for missing ride', () async {
    final response = await post(
      Uri.parse('$host/rides/missing/start'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001'}),
    );

    expect(response.statusCode, 404);
  });
  test('POST secure driver arriving returns 503 without driver auth', () async {
    final response = await post(
      Uri.parse('$host/driver/rides/ride-001/arriving'),
    );

    expect(response.statusCode, 503);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Driver authentication is unavailable.');
  });

  test('POST secure driver start returns 503 without driver auth', () async {
    final response = await post(Uri.parse('$host/driver/rides/ride-001/start'));

    expect(response.statusCode, 503);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Driver authentication is unavailable.');
  });

  test('POST secure driver complete returns 503 without driver auth', () async {
    final response = await post(
      Uri.parse('$host/driver/rides/ride-001/complete'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'meterFareMinor': 1234}),
    );

    expect(response.statusCode, 503);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Driver authentication is unavailable.');
  });
}

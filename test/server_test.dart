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
      environment: {'PORT': port, 'GOOGLE_MAPS_API_KEY': 'test-api-key'},
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

    expect(body['assignedDriverId'], isNull);
    expect(body['assignedVehicleId'], isNull);

    expect(body['requestedAt'], isNotNull);
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
  test('POST ride select accepts ride when driver is free', () async {
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
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    expect(response.statusCode, 200);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['status'], 'accepted');
    expect(body['assignedDriverId'], 'driver-001');
    expect(body['assignedVehicleId'], 'vehicle-001');
  });

  test('POST ride select reserves second ride when driver is busy', () async {
    Future<String> createRide(String pickup) async {
      final response = await post(
        Uri.parse('$host/rides'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'pickup': pickup,
          'destination': 'Destination address',
          'passengers': 1,
        }),
      );

      expect(response.statusCode, 201);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      return body['id'] as String;
    }

    final firstRideId = await createRide('First pickup');
    final secondRideId = await createRide('Second pickup');

    final firstSelection = await post(
      Uri.parse('$host/rides/$firstRideId/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    expect(firstSelection.statusCode, 200);

    final firstBody = jsonDecode(firstSelection.body) as Map<String, dynamic>;

    expect(firstBody['status'], 'accepted');

    final secondSelection = await post(
      Uri.parse('$host/rides/$secondRideId/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    expect(secondSelection.statusCode, 200);

    final secondBody = jsonDecode(secondSelection.body) as Map<String, dynamic>;

    expect(secondBody['status'], 'reserved');
    expect(secondBody['assignedDriverId'], 'driver-001');
    expect(secondBody['assignedVehicleId'], 'vehicle-001');
  });

  test(
    'POST ride select rejects third ride when driver already has reserved ride',
    () async {
      Future<String> createRide(String pickup) async {
        final response = await post(
          Uri.parse('$host/rides'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'pickup': pickup,
            'destination': 'Destination address',
            'passengers': 1,
          }),
        );

        expect(response.statusCode, 201);

        final body = jsonDecode(response.body) as Map<String, dynamic>;

        return body['id'] as String;
      }

      final firstRideId = await createRide('First pickup');
      final secondRideId = await createRide('Second pickup');
      final thirdRideId = await createRide('Third pickup');

      for (final rideId in [firstRideId, secondRideId]) {
        final response = await post(
          Uri.parse('$host/rides/$rideId/select'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'driverId': 'driver-001',
            'vehicleId': 'vehicle-001',
          }),
        );

        expect(response.statusCode, 200);
      }

      final response = await post(
        Uri.parse('$host/rides/$thirdRideId/select'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'driverId': 'driver-001',
          'vehicleId': 'vehicle-001',
        }),
      );

      expect(response.statusCode, 409);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      expect(body['error'], 'Ride cannot be selected.');
    },
  );

  test('POST ride select returns 404 for missing ride', () async {
    final response = await post(
      Uri.parse('$host/rides/missing/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    expect(response.statusCode, 404);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Ride not found.');
  });

  test('POST ride select requires driver and vehicle', () async {
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

    expect(response.statusCode, 400);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'driverId is required.');
  });
  test(
    'POST ride promote rejects reserved ride while driver is busy',
    () async {
      Future<String> createRide(String pickup) async {
        final response = await post(
          Uri.parse('$host/rides'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'pickup': pickup,
            'destination': 'Destination address',
            'passengers': 1,
          }),
        );

        expect(response.statusCode, 201);

        final body = jsonDecode(response.body) as Map<String, dynamic>;

        return body['id'] as String;
      }

      final firstRideId = await createRide('First pickup');
      final secondRideId = await createRide('Second pickup');

      final firstSelection = await post(
        Uri.parse('$host/rides/$firstRideId/select'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'driverId': 'driver-001',
          'vehicleId': 'vehicle-001',
        }),
      );

      expect(firstSelection.statusCode, 200);

      final secondSelection = await post(
        Uri.parse('$host/rides/$secondRideId/select'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'driverId': 'driver-001',
          'vehicleId': 'vehicle-001',
        }),
      );

      expect(secondSelection.statusCode, 200);

      final secondBody =
          jsonDecode(secondSelection.body) as Map<String, dynamic>;

      expect(secondBody['status'], 'reserved');

      final response = await post(
        Uri.parse('$host/rides/$secondRideId/promote'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'driverId': 'driver-001'}),
      );

      expect(response.statusCode, 409);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      expect(body['error'], 'Reserved ride cannot be promoted.');
    },
  );

  test('POST ride promote accepts reserved ride when driver is free', () async {
    Future<String> createRide(String pickup) async {
      final response = await post(
        Uri.parse('$host/rides'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'pickup': pickup,
          'destination': 'Destination address',
          'passengers': 1,
        }),
      );

      expect(response.statusCode, 201);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      return body['id'] as String;
    }

    final firstRideId = await createRide('First pickup');
    final secondRideId = await createRide('Second pickup');

    final firstSelection = await post(
      Uri.parse('$host/rides/$firstRideId/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    expect(firstSelection.statusCode, 200);

    final secondSelection = await post(
      Uri.parse('$host/rides/$secondRideId/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    expect(secondSelection.statusCode, 200);

    final reservedBody =
        jsonDecode(secondSelection.body) as Map<String, dynamic>;

    expect(reservedBody['status'], 'reserved');

    final cancelFirstRide = await post(
      Uri.parse('$host/rides/$firstRideId/cancel'),
    );

    expect(cancelFirstRide.statusCode, 200);

    final response = await post(
      Uri.parse('$host/rides/$secondRideId/promote'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001'}),
    );

    expect(response.statusCode, 200);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['id'], secondRideId);
    expect(body['status'], 'accepted');
    expect(body['assignedDriverId'], 'driver-001');
    expect(body['assignedVehicleId'], 'vehicle-001');
  });

  test('POST ride promote rejects different driver', () async {
    Future<String> createRide(String pickup) async {
      final response = await post(
        Uri.parse('$host/rides'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'pickup': pickup,
          'destination': 'Destination address',
          'passengers': 1,
        }),
      );

      expect(response.statusCode, 201);

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      return body['id'] as String;
    }

    final firstRideId = await createRide('First pickup');
    final secondRideId = await createRide('Second pickup');

    await post(
      Uri.parse('$host/rides/$firstRideId/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    await post(
      Uri.parse('$host/rides/$secondRideId/select'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001', 'vehicleId': 'vehicle-001'}),
    );

    final response = await post(
      Uri.parse('$host/rides/$secondRideId/promote'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-002'}),
    );

    expect(response.statusCode, 409);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Reserved ride cannot be promoted.');
  });

  test('POST ride promote returns 404 for missing ride', () async {
    final response = await post(
      Uri.parse('$host/rides/missing/promote'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'driverId': 'driver-001'}),
    );

    expect(response.statusCode, 404);

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body['error'], 'Ride not found.');
  });
}

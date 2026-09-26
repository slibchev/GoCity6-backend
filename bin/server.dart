import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:gocity6_backend/ride/in_memory_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_lifecycle_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_dispatch_service.dart';

Future<Map<String, double>> geocodeAddress(
  String address,
  String apiKey,
) async {
  final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
    'address': address,
    'key': apiKey,
  });

  final response = await http.get(uri);

  if (response.statusCode != 200) {
    throw Exception('Geocoding request failed.');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;

  if (data['status'] != 'OK') {
    throw Exception(
      'Geocoding failed for "$address". '
      'Status: ${data['status']}. '
      'Message: ${data['error_message'] ?? 'No error message'}',
    );
  }

  final results = data['results'] as List<dynamic>;
  final location =
      results.first['geometry']['location'] as Map<String, dynamic>;

  return {
    'lat': (location['lat'] as num).toDouble(),
    'lng': (location['lng'] as num).toDouble(),
  };
}

Future<Map<String, dynamic>> buildRouteWaypoint({
  required String address,
  required String apiKey,
  String? placeId,
  double? latitude,
  double? longitude,
}) async {
  if (latitude != null && longitude != null) {
    return {
      'location': {
        'latLng': {'latitude': latitude, 'longitude': longitude},
      },
    };
  }

  if (placeId != null && placeId.isNotEmpty) {
    return {'placeId': placeId};
  }

  final coordinates = await geocodeAddress(address, apiKey);

  return {
    'location': {
      'latLng': {
        'latitude': coordinates['lat'],
        'longitude': coordinates['lng'],
      },
    },
  };
}

Future<Map<String, dynamic>> calculateRoute(
  String pickup,
  String destination,
  String apiKey, {
  String? pickupPlaceId,
  String? destinationPlaceId,
  double? pickupLatitude,
  double? pickupLongitude,
}) async {
  final origin = await buildRouteWaypoint(
    address: pickup,
    apiKey: apiKey,
    placeId: pickupPlaceId,
    latitude: pickupLatitude,
    longitude: pickupLongitude,
  );

  final destinationWaypoint = await buildRouteWaypoint(
    address: destination,
    apiKey: apiKey,
    placeId: destinationPlaceId,
  );

  final uri = Uri.parse(
    'https://routes.googleapis.com/directions/v2:computeRoutes',
  );

  final response = await http.post(
    uri,
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask':
          'routes.distanceMeters,'
          'routes.duration,'
          'routes.legs.startLocation,'
          'routes.legs.endLocation,'
          'routes.polyline.encodedPolyline',
    },
    body: jsonEncode({
      'origin': origin,
      'destination': destinationWaypoint,
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE',
      'units': 'METRIC',
    }),
  );

  if (response.statusCode != 200) {
    throw Exception('Route request failed.');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;

  final routes = data['routes'] as List<dynamic>? ?? <dynamic>[];

  if (routes.isEmpty) {
    throw Exception('No route found. Google response: ${response.body}');
  }

  final route = routes.first as Map<String, dynamic>;
  print('Google route response: ${response.body}');
  final polyline = route['polyline'] as Map<String, dynamic>?;
  final encodedPolyline = polyline?['encodedPolyline'] as String?;

  final distanceMeters = (route['distanceMeters'] as num?)?.toDouble() ?? 0.0;

  final durationText = route['duration'] as String? ?? '0s';

  final durationSeconds = double.parse(durationText.replaceAll('s', ''));

  final legs = route['legs'] as List<dynamic>?;

  if (legs == null || legs.isEmpty) {
    throw Exception('Route has no legs.');
  }

  final firstLeg = legs.first as Map<String, dynamic>;
  final lastLeg = legs.last as Map<String, dynamic>;

  final startLocation = firstLeg['startLocation'] as Map<String, dynamic>;
  final startLatLng = startLocation['latLng'] as Map<String, dynamic>;

  final endLocation = lastLeg['endLocation'] as Map<String, dynamic>;
  final endLatLng = endLocation['latLng'] as Map<String, dynamic>;

  return {
    'distanceKm': distanceMeters / 1000,
    'durationMinutes': durationSeconds / 60,
    'pickupLatitude': (startLatLng['latitude'] as num).toDouble(),
    'pickupLongitude': (startLatLng['longitude'] as num).toDouble(),
    'destinationLatitude': (endLatLng['latitude'] as num).toDouble(),
    'destinationLongitude': (endLatLng['longitude'] as num).toDouble(),
    'encodedPolyline': encodedPolyline,
  };
}

Map<String, dynamic> rideRequestToJson(RideRequest ride) {
  return {
    'id': ride.id,
    'pickup': ride.pickup,
    'destination': ride.destination,
    'passengers': ride.passengers,
    'hasLuggage': ride.hasLuggage,
    'requestedAt': ride.requestedAt.toUtc().toIso8601String(),
    'status': ride.status.name,
    'assignedDriverId': ride.assignedDriverId,
    'assignedVehicleId': ride.assignedVehicleId,
    'completedByDriverId': ride.completedByDriverId,
    'completedAt': ride.completedAt?.toUtc().toIso8601String(),
  };
}

const corsResponseHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept',
};

Middleware corsMiddleware() {
  return createMiddleware(
    requestHandler: (request) {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: corsResponseHeaders);
      }

      return null;
    },
    responseHandler: (response) {
      return response.change(headers: corsResponseHeaders);
    },
  );
}

Future<List<Map<String, String>>> autocompletePlaces(
  String input,
  String apiKey, {
  String? sessionToken,
}) async {
  final response = await http.post(
    Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask':
          'suggestions.placePrediction.placeId,'
          'suggestions.placePrediction.text.text',
    },
    body: jsonEncode({
      'input': input,
      'includedRegionCodes': ['bg'],
      'languageCode': 'bg',
      if (sessionToken != null && sessionToken.isNotEmpty)
        'sessionToken': sessionToken,
    }),
  );

  if (response.statusCode != 200) {
    throw Exception(
      'Places autocomplete failed with status '
      '${response.statusCode}.',
    );
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final suggestions = data['suggestions'] as List<dynamic>? ?? <dynamic>[];

  final results = <Map<String, String>>[];

  for (final suggestion in suggestions) {
    final prediction =
        (suggestion as Map<String, dynamic>)['placePrediction']
            as Map<String, dynamic>?;

    if (prediction == null) {
      continue;
    }

    final placeId = prediction['placeId'] as String?;
    final textData = prediction['text'] as Map<String, dynamic>?;
    final text = textData?['text'] as String?;

    if (placeId != null && text != null) {
      results.add({'placeId': placeId, 'text': text});
    }
  }

  return results;
}

void main(List<String> args) async {
  final apiKey = Platform.environment['GOOGLE_MAPS_API_KEY'];

  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('GOOGLE_MAPS_API_KEY is not configured.');
    exit(1);
  }

  final router = Router();
  final rideRepository = InMemoryRideRequestRepository();

  final rideLifecycleService = RideLifecycleService(repository: rideRepository);
  final rideDispatchService = RideDispatchService(repository: rideRepository);

  var nextRideNumber = 1;

  router.get('/', (Request request) {
    return Response.ok('GoCity6 backend is running');
  });
  router.post('/rides', (Request request) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,
          body: jsonEncode({'error': 'Request body must be a JSON object.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final pickup = decodedBody['pickup'];
      final destination = decodedBody['destination'];
      final passengers = decodedBody['passengers'];
      final hasLuggage = decodedBody['hasLuggage'];

      if (pickup is! String ||
          pickup.trim().isEmpty ||
          destination is! String ||
          destination.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'Pickup and destination are required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      if (passengers is! int || passengers < 1) {
        return Response(
          400,
          body: jsonEncode({'error': 'Passengers must be a positive integer.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      if (hasLuggage != null && hasLuggage is! bool) {
        return Response(
          400,
          body: jsonEncode({'error': 'hasLuggage must be a boolean.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final ride = RideRequest(
        id: 'ride-${nextRideNumber++}',
        pickup: pickup.trim(),
        destination: destination.trim(),
        passengers: passengers,
        hasLuggage: hasLuggage as bool? ?? false,
        requestedAt: DateTime.now().toUtc(),
      );

      final submittedRide = await rideLifecycleService.submitRide(ride);

      return Response(
        201,
        body: jsonEncode(rideRequestToJson(submittedRide)),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,
        body: jsonEncode({'error': 'Invalid JSON body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Create ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride creation failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.get('/rides/<rideId>', (Request request, String rideId) async {
    try {
      final ride = await rideLifecycleService.getRide(rideId);

      return Response.ok(
        jsonEncode(rideRequestToJson(ride)),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,
        body: jsonEncode({'error': 'Ride not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Get ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to load ride.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.post('/rides/<rideId>/cancel', (Request request, String rideId) async {
    try {
      final cancelledRide = await rideLifecycleService.cancelRide(rideId);

      return Response.ok(
        jsonEncode(rideRequestToJson(cancelledRide)),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,
        body: jsonEncode({'error': 'Ride not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleConflictException {
      return Response(
        409,
        body: jsonEncode({'error': 'Ride cannot be cancelled.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Cancel ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride cancellation failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.post('/rides/<rideId>/select', (Request request, String rideId) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,
          body: jsonEncode({'error': 'Request body must be a JSON object.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];
      final vehicleId = decodedBody['vehicleId'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'driverId is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      if (vehicleId is! String || vehicleId.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'vehicleId is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final selectedRide = await rideDispatchService.selectWaitingRide(
        rideId: rideId,
        driverId: driverId.trim(),
        vehicleId: vehicleId.trim(),
      );

      return Response.ok(
        jsonEncode(rideRequestToJson(selectedRide)),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,
        body: jsonEncode({'error': 'Invalid JSON body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideNotFoundException {
      return Response(
        404,
        body: jsonEncode({'error': 'Ride not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideDispatchConflictException {
      return Response(
        409,
        body: jsonEncode({'error': 'Ride cannot be selected.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Select ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride selection failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.post('/rides/<rideId>/promote', (
    Request request,
    String rideId,
  ) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,
          body: jsonEncode({'error': 'Request body must be a JSON object.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'driverId is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final promotedRide = await rideDispatchService.promoteReservedRide(
        rideId: rideId,
        driverId: driverId.trim(),
      );

      return Response.ok(
        jsonEncode(rideRequestToJson(promotedRide)),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,
        body: jsonEncode({'error': 'Invalid JSON body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideNotFoundException {
      return Response(
        404,
        body: jsonEncode({'error': 'Ride not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideDispatchConflictException {
      return Response(
        409,
        body: jsonEncode({'error': 'Reserved ride cannot be promoted.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Promote ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride promotion failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.post('/rides/<rideId>/driver-arriving', (
    Request request,
    String rideId,
  ) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,
          body: jsonEncode({'error': 'Request body must be a JSON object.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'driverId is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final updatedRide = await rideLifecycleService.markDriverArriving(
        rideId: rideId,
        driverId: driverId.trim(),
      );

      return Response.ok(
        jsonEncode(rideRequestToJson(updatedRide)),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,
        body: jsonEncode({'error': 'Invalid JSON body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,
        body: jsonEncode({'error': 'Ride not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleConflictException {
      return Response(
        409,
        body: jsonEncode({'error': 'Ride cannot move to driverArriving.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Driver arriving error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to update ride.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.post('/rides/<rideId>/start', (Request request, String rideId) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,
          body: jsonEncode({'error': 'Request body must be a JSON object.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'driverId is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final updatedRide = await rideLifecycleService.startRide(
        rideId: rideId,
        driverId: driverId.trim(),
      );

      return Response.ok(
        jsonEncode(rideRequestToJson(updatedRide)),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,
        body: jsonEncode({'error': 'Invalid JSON body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,
        body: jsonEncode({'error': 'Ride not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleConflictException {
      return Response(
        409,
        body: jsonEncode({'error': 'Ride cannot be started.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Start ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to start ride.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/route', (Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;

      final pickup = body['pickup'] as String?;
      final destination = body['destination'] as String?;
      final pickupPlaceId = body['pickupPlaceId'] as String?;
      final destinationPlaceId = body['destinationPlaceId'] as String?;
      final pickupLatitude = (body['pickupLatitude'] as num?)?.toDouble();
      final pickupLongitude = (body['pickupLongitude'] as num?)?.toDouble();

      if (pickup == null ||
          pickup.trim().isEmpty ||
          destination == null ||
          destination.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'Pickup and destination are required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final result = await calculateRoute(
        pickup,
        destination,
        apiKey,
        pickupPlaceId: pickupPlaceId,
        destinationPlaceId: destinationPlaceId,
        pickupLatitude: pickupLatitude,
        pickupLongitude: pickupLongitude,
      );

      return Response.ok(
        jsonEncode(result),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Route error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Route calculation failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/places/autocomplete', (Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;

      final input = body['input'] as String?;
      final sessionToken = body['sessionToken'] as String?;

      if (input == null || input.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'Input is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final suggestions = await autocompletePlaces(
        input.trim(),
        apiKey,
        sessionToken: sessionToken,
      );

      return Response.ok(
        jsonEncode({'suggestions': suggestions}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Places autocomplete error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Places autocomplete failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler(router.call);

  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);

  print('Server listening on port ${server.port}');
}

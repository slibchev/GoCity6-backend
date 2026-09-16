import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

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

Future<Map<String, dynamic>> calculateRoute(
  String pickup,
  String destination,
  String apiKey,
) async {
  final pickupCoordinates = await geocodeAddress(pickup, apiKey);

  final destinationCoordinates = await geocodeAddress(destination, apiKey);

  final uri = Uri.parse(
    'https://routes.googleapis.com/directions/v2:computeRoutes',
  );

  final response = await http.post(
    uri,
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'routes.distanceMeters,routes.duration',
    },
    body: jsonEncode({
      'origin': {
        'location': {
          'latLng': {
            'latitude': pickupCoordinates['lat'],
            'longitude': pickupCoordinates['lng'],
          },
        },
      },
      'destination': {
        'location': {
          'latLng': {
            'latitude': destinationCoordinates['lat'],
            'longitude': destinationCoordinates['lng'],
          },
        },
      },
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE',
      'units': 'METRIC',
    }),
  );

  if (response.statusCode != 200) {
    throw Exception('Route request failed.');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final routes = data['routes'] as List<dynamic>;

  if (routes.isEmpty) {
    throw Exception('No route found.');
  }

  final route = routes.first as Map<String, dynamic>;

  final distanceMeters = route['distanceMeters'] as int;
  final durationText = route['duration'] as String;

  final durationSeconds = double.parse(durationText.replaceAll('s', ''));

  return {
    'distanceKm': distanceMeters / 1000,
    'durationMinutes': durationSeconds / 60,
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

  router.get('/', (Request request) {
    return Response.ok('GoCity6 backend is running');
  });

  router.post('/route', (Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;

      final pickup = body['pickup'] as String?;
      final destination = body['destination'] as String?;

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

      final result = await calculateRoute(pickup, destination, apiKey);

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

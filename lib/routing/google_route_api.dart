import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

class RouteCalculationTimeoutException implements Exception {
  const RouteCalculationTimeoutException();
}

/// Handles route requests using one deadline shared by geocoding and Routes.
class GoogleRouteApi {
  GoogleRouteApi({
    required this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client() {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  final String apiKey;
  final http.Client _client;
  final Duration timeout;

  Future<Response> handle(Request request) async {
    final deadline = _RouteRequestDeadline(timeout);
    try {
      return await deadline.run(() async {
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

        final result = await _calculateRoute(
          pickup,
          destination,
          deadline,
          pickupPlaceId: pickupPlaceId,
          destinationPlaceId: destinationPlaceId,
          pickupLatitude: pickupLatitude,
          pickupLongitude: pickupLongitude,
        );

        return Response.ok(
          jsonEncode(result),
          headers: {'Content-Type': 'application/json'},
        );
      });
    } on RouteCalculationTimeoutException {
      return _timeoutResponse();
    } catch (error) {
      if (deadline.expired) {
        return _timeoutResponse();
      }
      print('Route calculation failed.');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Route calculation failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } finally {
      deadline.dispose();
    }
  }

  Response _timeoutResponse() => Response(
    504,
    body: jsonEncode({'error': 'Route calculation timed out.'}),
    headers: {'Content-Type': 'application/json'},
  );

  Future<Map<String, dynamic>> _calculateRoute(
    String pickup,
    String destination,
    _RouteRequestDeadline deadline, {
    String? pickupPlaceId,
    String? destinationPlaceId,
    double? pickupLatitude,
    double? pickupLongitude,
  }) async {
    final origin = await _buildRouteWaypoint(
      address: pickup,
      deadline: deadline,
      placeId: pickupPlaceId,
      latitude: pickupLatitude,
      longitude: pickupLongitude,
    );
    final destinationWaypoint = await _buildRouteWaypoint(
      address: destination,
      deadline: deadline,
      placeId: destinationPlaceId,
    );

    final response = await _send(
      deadline,
      http.Request(
          'POST',
          Uri.parse(
            'https://routes.googleapis.com/directions/v2:computeRoutes',
          ),
        )
        ..headers.addAll({
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
              'routes.distanceMeters,'
              'routes.duration,'
              'routes.legs.startLocation,'
              'routes.legs.endLocation,'
              'routes.polyline.encodedPolyline',
        })
        ..body = jsonEncode({
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

  Future<Map<String, dynamic>> _buildRouteWaypoint({
    required String address,
    required _RouteRequestDeadline deadline,
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

    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': address,
      'key': apiKey,
    });
    final response = await _send(deadline, http.Request('GET', uri));

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
    final latitudeValue = (location['lat'] as num).toDouble();
    final longitudeValue = (location['lng'] as num).toDouble();

    return {
      'location': {
        'latLng': {'latitude': latitudeValue, 'longitude': longitudeValue},
      },
    };
  }

  Future<http.Response> _send(
    _RouteRequestDeadline deadline,
    http.Request request,
  ) async {
    final abortableRequest =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: deadline.abortTrigger,
          )
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;

    final streamedResponse = await _client.send(abortableRequest);
    return http.Response.fromStream(streamedResponse);
  }
}

class _RouteRequestDeadline {
  _RouteRequestDeadline(Duration timeout) {
    _timer = Timer(timeout, () {
      _timedOut = true;
      _abortCompleter.complete();
      _timeoutCompleter.complete();
    });
  }

  final _abortCompleter = Completer<void>();
  final _timeoutCompleter = Completer<void>();
  late final Timer _timer;
  bool _timedOut = false;

  Future<void> get abortTrigger => _abortCompleter.future;
  bool get expired => _timedOut;

  Future<T> run<T>(Future<T> Function() operation) {
    if (_timedOut) {
      return Future<T>.error(const RouteCalculationTimeoutException());
    }
    return Future.any<T>([
      Future<T>.sync(operation),
      _timeoutCompleter.future.then<T>(
        (_) => throw const RouteCalculationTimeoutException(),
      ),
    ]);
  }

  void dispose() => _timer.cancel();
}

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'route_estimator.dart';

class GoogleRouteEstimator implements RouteEstimator, BatchRouteEstimator {
  final String apiKey;
  final http.Client client;

  GoogleRouteEstimator({required this.apiKey, http.Client? client})
    : client = client ?? http.Client() {
    if (apiKey.isEmpty) {
      throw ArgumentError.value(
        apiKey,
        'apiKey',
        'Google Maps API key cannot be empty.',
      );
    }
  }

  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    final originPayload = await _buildWaypoint(origin);
    final destinationPayload = await _buildWaypoint(destination);

    final response = await client.post(
      Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
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
        'origin': originPayload,
        'destination': destinationPayload,
        'travelMode': 'DRIVE',
        'routingPreference': 'TRAFFIC_AWARE',
        'units': 'METRIC',
      }),
    );

    if (response.statusCode != 200) {
      throw StateError(
        'Google Routes request failed with status '
        '${response.statusCode}.',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>? ?? const [];

    if (routes.isEmpty) {
      throw StateError('Google Routes returned no route.');
    }

    final route = routes.first as Map<String, dynamic>;

    final distanceMeters = (route['distanceMeters'] as num?)?.toDouble() ?? 0.0;

    final durationText = route['duration'] as String?;

    if (durationText == null) {
      throw StateError('Google Routes response is missing duration.');
    }

    final durationSeconds = _parseDurationSeconds(durationText);

    final legs = route['legs'] as List<dynamic>?;

    if (legs == null || legs.isEmpty) {
      throw StateError('Google Routes response has no legs.');
    }

    final firstLeg = legs.first as Map<String, dynamic>;
    final lastLeg = legs.last as Map<String, dynamic>;

    final startLatLng = _readLatLng(firstLeg['startLocation']);

    final endLatLng = _readLatLng(lastLeg['endLocation']);

    final polyline = route['polyline'] as Map<String, dynamic>?;

    return RouteEstimate(
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      originLatitude: startLatLng?.$1,
      originLongitude: startLatLng?.$2,
      destinationLatitude: endLatLng?.$1,
      destinationLongitude: endLatLng?.$2,
      encodedPolyline: polyline?['encodedPolyline'] as String?,
    );
  }

  @override
  Future<List<RouteEstimate?>> estimateMany({
    required List<RouteWaypoint> origins,
    required RouteWaypoint destination,
  }) async {
    if (origins.isEmpty) {
      return const [];
    }

    final destinationPayload = await _buildWaypoint(destination);
    final estimates = List<RouteEstimate?>.filled(origins.length, null);
    const batchSize = 50;
    final requests = <Future<void>>[];

    for (var start = 0; start < origins.length; start += batchSize) {
      final end = (start + batchSize < origins.length)
          ? start + batchSize
          : origins.length;
      final chunkStart = start;
      final chunk = origins.sublist(start, end);

      requests.add(() async {
        final originPayloads = await Future.wait(chunk.map(_buildWaypoint));
        final response = await client.post(
          Uri.parse(
            'https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix',
          ),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': apiKey,
            'X-Goog-FieldMask': 'originIndex,destinationIndex,duration,distanceMeters,condition',
          },
          body: jsonEncode({
            'origins': originPayloads
                .map((origin) => {'waypoint': origin})
                .toList(growable: false),
            'destinations': [
              {'waypoint': destinationPayload},
            ],
            'travelMode': 'DRIVE',
            'routingPreference': 'TRAFFIC_AWARE',
            'units': 'METRIC',
          }),
        );

        if (response.statusCode != 200) {
          throw StateError(
            'Google Routes matrix request failed with status '
            '${response.statusCode}.',
          );
        }

        final decoded = jsonDecode(response.body);
        final elements = decoded is List<dynamic>
            ? decoded
            : (decoded is Map<String, dynamic>
                  ? decoded['matrixElements'] as List<dynamic>?
                  : null);

        if (elements == null) {
          throw StateError('Google Routes matrix returned an invalid body.');
        }

        for (final element in elements) {
          if (element is! Map<String, dynamic>) {
            continue;
          }

          final originIndex = element['originIndex'];
          final destinationIndex = element['destinationIndex'];

          if (originIndex is! int || destinationIndex != 0) {
            continue;
          }

          if (originIndex < 0 || originIndex >= chunk.length) {
            continue;
          }

          if (element['condition'] != 'ROUTE_EXISTS') {
            continue;
          }

          final durationText = element['duration'] as String?;
          final distanceMeters = element['distanceMeters'];

          if (durationText == null || distanceMeters is! num) {
            continue;
          }

          estimates[chunkStart + originIndex] = RouteEstimate(
            durationSeconds: _parseDurationSeconds(durationText),
            distanceMeters: distanceMeters.toDouble(),
          );
        }
      }());
    }

    await Future.wait(requests);

    return List.unmodifiable(estimates);
  }

  Future<Map<String, dynamic>> _buildWaypoint(RouteWaypoint waypoint) async {
    final latitude = waypoint.latitude;
    final longitude = waypoint.longitude;

    if (latitude != null && longitude != null) {
      if (!_isValidCoordinate(latitude, longitude)) {
        throw const RouteWaypointResolutionException(
          RouteWaypointFailureReason.invalidCoordinates,
        );
      }

      return {
        'location': {
          'latLng': {'latitude': latitude, 'longitude': longitude},
        },
      };
    }

    final placeId = waypoint.placeId?.trim();

    if (placeId != null && placeId.isNotEmpty) {
      return {'placeId': placeId};
    }

    final address = waypoint.address?.trim();

    if (address == null || address.isEmpty) {
      throw StateError('Route waypoint cannot be resolved.');
    }

    final coordinates = await _geocodeAddress(address);

    return {
      'location': {
        'latLng': {'latitude': coordinates.$1, 'longitude': coordinates.$2},
      },
    };
  }

  Future<(double, double)> _geocodeAddress(String address) async {
    final response = await client.get(
      Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'address': address,
        'key': apiKey,
      }),
    );

    if (response.statusCode != 200) {
      throw StateError(
        'Google Geocoding request failed with status '
        '${response.statusCode}.',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    final status = data['status'];

    if (status == 'ZERO_RESULTS') {
      throw const RouteWaypointResolutionException(
        RouteWaypointFailureReason.geocodingNoResults,
      );
    }

    if (status != 'OK') {
      throw StateError('Google Geocoding failed with status $status.');
    }

    final results = data['results'] as List<dynamic>? ?? const [];

    if (results.isEmpty) {
      throw StateError('Google Geocoding returned no results.');
    }

    final firstResult = results.first as Map<String, dynamic>;
    final geometry = firstResult['geometry'] as Map<String, dynamic>?;
    final location = geometry?['location'] as Map<String, dynamic>?;

    final latitude = (location?['lat'] as num?)?.toDouble();
    final longitude = (location?['lng'] as num?)?.toDouble();

    if (latitude == null || longitude == null) {
      throw StateError('Google Geocoding response is missing coordinates.');
    }

    if (!_isValidCoordinate(latitude, longitude)) {
      throw const RouteWaypointResolutionException(
        RouteWaypointFailureReason.invalidCoordinates,
      );
    }

    return (latitude, longitude);
  }

  bool _isValidCoordinate(double latitude, double longitude) {
    return latitude.isFinite &&
        longitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180;
  }

  double _parseDurationSeconds(String durationText) {
    if (!durationText.endsWith('s')) {
      throw StateError('Unsupported Google route duration: $durationText');
    }

    final seconds = double.tryParse(
      durationText.substring(0, durationText.length - 1),
    );

    if (seconds == null || seconds < 0) {
      throw StateError('Invalid Google route duration: $durationText');
    }

    return seconds;
  }

  (double, double)? _readLatLng(Object? locationValue) {
    final location = locationValue as Map<String, dynamic>?;
    final latLng = location?['latLng'] as Map<String, dynamic>?;

    final latitude = (latLng?['latitude'] as num?)?.toDouble();
    final longitude = (latLng?['longitude'] as num?)?.toDouble();

    if (latitude == null || longitude == null) {
      return null;
    }

    return (latitude, longitude);
  }
}

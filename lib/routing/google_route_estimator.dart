import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'route_estimator.dart';

class GoogleRouteEstimator
    implements
        RouteEstimator,
        BatchRouteEstimator,
        MultiDestinationRouteEstimator {
  final String apiKey;
  final http.Client client;
  final Duration requestTimeout;

  GoogleRouteEstimator({
    required this.apiKey,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 4),
  }) : client = client ?? http.Client() {
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

    final response = await _postJson(
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
      body: {
        'origin': originPayload,
        'destination': destinationPayload,
        'travelMode': 'DRIVE',
        'routingPreference': 'TRAFFIC_AWARE',
        'units': 'METRIC',
      },
    );

    if (response.statusCode != 200) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.providerRejected,
      );
    }

    final decoded = _decodeProviderResponse(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final routesValue = decoded['routes'];
    if (routesValue != null && routesValue is! List<dynamic>) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final routes = routesValue as List<dynamic>? ?? const [];

    if (routes.isEmpty) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.routeUnavailable,
      );
    }

    final routeValue = routes.first;
    if (routeValue is! Map<String, dynamic>) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final route = routeValue;

    final distanceValue = route['distanceMeters'];
    if (distanceValue is! num ||
        !distanceValue.toDouble().isFinite ||
        distanceValue < 0) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final distanceMeters = distanceValue.toDouble();

    final durationValue = route['duration'];

    if (durationValue is! String) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }

    final durationSeconds = _parseDurationSeconds(durationValue);

    final legsValue = route['legs'];

    if (legsValue is! List<dynamic> || legsValue.isEmpty) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }

    final firstLegValue = legsValue.first;
    final lastLegValue = legsValue.last;
    if (firstLegValue is! Map<String, dynamic> ||
        lastLegValue is! Map<String, dynamic>) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final firstLeg = firstLegValue;
    final lastLeg = lastLegValue;

    final startLatLng = _readLatLng(firstLeg['startLocation']);

    final endLatLng = _readLatLng(lastLeg['endLocation']);

    final polylineValue = route['polyline'];
    final polyline = polylineValue is Map<String, dynamic>
        ? polylineValue['encodedPolyline']
        : null;

    return RouteEstimate(
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      originLatitude: startLatLng?.$1,
      originLongitude: startLatLng?.$2,
      destinationLatitude: endLatLng?.$1,
      destinationLongitude: endLatLng?.$2,
      encodedPolyline: polyline is String ? polyline : null,
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
        final response = await _postJson(
          Uri.parse(
            'https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix',
          ),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': apiKey,
            'X-Goog-FieldMask': 'originIndex,destinationIndex,duration,distanceMeters,condition',
          },
          body: {
            'origins': originPayloads
                .map((origin) => {'waypoint': origin})
                .toList(growable: false),
            'destinations': [
              {'waypoint': destinationPayload},
            ],
            'travelMode': 'DRIVE',
            'routingPreference': 'TRAFFIC_AWARE',
            'units': 'METRIC',
          },
        );

        if (response.statusCode != 200) {
          throw RouteEstimationFailure(
            RouteEstimationFailureReason.providerRejected,
          );
        }

        final decoded = _decodeProviderResponse(response.body);
        final elementsValue = decoded is List<dynamic>
            ? decoded
            : (decoded is Map<String, dynamic>
                  ? decoded['matrixElements']
                  : null);

        if (elementsValue is! List<dynamic>) {
          throw RouteEstimationFailure(
            RouteEstimationFailureReason.invalidProviderResponse,
          );
        }
        final elements = elementsValue;

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

          final durationText = element['duration'];
          final distanceMeters = element['distanceMeters'];

          if (durationText is! String ||
              distanceMeters is! num ||
              !distanceMeters.toDouble().isFinite ||
              distanceMeters < 0) {
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

  @override
  Future<List<RouteEstimate?>> estimateToMany({
    required RouteWaypoint origin,
    required List<RouteWaypoint> destinations,
  }) async {
    if (destinations.isEmpty) return const [];

    final originPayload = await _buildWaypoint(origin);
    final estimates = List<RouteEstimate?>.filled(destinations.length, null);
    const batchSize = 50;

    for (var start = 0; start < destinations.length; start += batchSize) {
      final end = start + batchSize < destinations.length
          ? start + batchSize
          : destinations.length;
      final chunk = destinations.sublist(start, end);
      final payloads = await Future.wait(
        chunk.map((waypoint) async {
          try {
            return await _buildWaypoint(waypoint);
          } on RouteWaypointResolutionException {
            // An unresolved pickup must not fail the other waiting rides.
            return null;
          } on RouteEstimationFailure {
            // A temporary geocoding/provider failure only excludes this ride.
            return null;
          }
        }),
      );
      final validIndexes = <int>[];
      for (var i = 0; i < payloads.length; i++) {
        if (payloads[i] != null) validIndexes.add(i);
      }
      if (validIndexes.isEmpty) continue;

      final response = await _postJson(
        Uri.parse(
          'https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix',
        ),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
              'originIndex,destinationIndex,duration,distanceMeters,condition',
        },
        body: {
          'origins': [
            {'waypoint': originPayload},
          ],
          'destinations': validIndexes
              .map((index) => {'waypoint': payloads[index]})
              .toList(growable: false),
          'travelMode': 'DRIVE',
          'routingPreference': 'TRAFFIC_AWARE',
          'units': 'METRIC',
        },
      );

      if (response.statusCode != 200) {
        throw RouteEstimationFailure(
          RouteEstimationFailureReason.providerRejected,
        );
      }
      final decoded = _decodeProviderResponse(response.body);
      final elementsValue = decoded is List<dynamic>
          ? decoded
          : (decoded is Map<String, dynamic>
                ? decoded['matrixElements']
                : null);
      if (elementsValue is! List<dynamic>) {
        throw RouteEstimationFailure(
          RouteEstimationFailureReason.invalidProviderResponse,
        );
      }
      final elements = elementsValue;

      for (final element in elements) {
        if (element is! Map<String, dynamic> ||
            element['originIndex'] != 0 ||
            element['condition'] != 'ROUTE_EXISTS') {
          continue;
        }
        final destinationIndex = element['destinationIndex'];
        final durationText = element['duration'];
        final distanceMeters = element['distanceMeters'];
        if (destinationIndex is! int ||
            destinationIndex < 0 ||
            destinationIndex >= validIndexes.length ||
            durationText is! String ||
            distanceMeters is! num ||
            !distanceMeters.toDouble().isFinite ||
            distanceMeters < 0) {
          continue;
        }
        final originalIndex = start + validIndexes[destinationIndex];
        estimates[originalIndex] = RouteEstimate(
          durationSeconds: _parseDurationSeconds(durationText),
          distanceMeters: distanceMeters.toDouble(),
        );
      }
    }
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
    final response = await _get(
      Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'address': address,
        'key': apiKey,
      }),
    );

    if (response.statusCode != 200) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.providerRejected,
      );
    }

    final decoded = _decodeProviderResponse(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final data = decoded;

    final status = data['status'];

    if (status == 'ZERO_RESULTS') {
      throw const RouteWaypointResolutionException(
        RouteWaypointFailureReason.geocodingNoResults,
      );
    }

    if (status != 'OK') {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.providerRejected,
      );
    }

    final resultsValue = data['results'];
    if (resultsValue != null && resultsValue is! List<dynamic>) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final results = resultsValue as List<dynamic>? ?? const [];

    if (results.isEmpty) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }

    final firstResult = results.first;
    if (firstResult is! Map<String, dynamic>) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
    final geometryValue = firstResult['geometry'];
    final geometry = geometryValue is Map<String, dynamic>
        ? geometryValue
        : null;
    final locationValue = geometry?['location'];
    final location = locationValue is Map<String, dynamic>
        ? locationValue
        : null;

    final latitudeValue = location?['lat'];
    final longitudeValue = location?['lng'];
    final latitude = latitudeValue is num ? latitudeValue.toDouble() : null;
    final longitude = longitudeValue is num ? longitudeValue.toDouble() : null;

    if (latitude == null || longitude == null) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }

    if (!_isValidCoordinate(latitude, longitude)) {
      throw const RouteWaypointResolutionException(
        RouteWaypointFailureReason.invalidCoordinates,
      );
    }

    return (latitude, longitude);
  }

  Future<http.Response> _postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    try {
      return await client
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw RouteEstimationFailure(RouteEstimationFailureReason.timeout);
    } on http.ClientException {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.networkUnavailable,
      );
    } on SocketException {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.networkUnavailable,
      );
    } on StateError {
      // Some HTTP/provider adapters surface transport failures as StateError.
      // Keep this recovery scoped to the external request; unrelated
      // StateErrors elsewhere in route construction remain visible.
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.networkUnavailable,
      );
    }
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      return await client.get(uri).timeout(requestTimeout);
    } on TimeoutException {
      throw RouteEstimationFailure(RouteEstimationFailureReason.timeout);
    } on http.ClientException {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.networkUnavailable,
      );
    } on SocketException {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.networkUnavailable,
      );
    } on StateError {
      // See _postJson: only an error emitted by this external request is
      // classified as a recoverable route-provider failure.
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.networkUnavailable,
      );
    }
  }

  Object? _decodeProviderResponse(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }
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
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }

    final seconds = double.tryParse(
      durationText.substring(0, durationText.length - 1),
    );

    if (seconds == null || !seconds.isFinite || seconds < 0) {
      throw RouteEstimationFailure(
        RouteEstimationFailureReason.invalidProviderResponse,
      );
    }

    return seconds;
  }

  (double, double)? _readLatLng(Object? locationValue) {
    if (locationValue is! Map<String, dynamic>) return null;
    final latLngValue = locationValue['latLng'];
    if (latLngValue is! Map<String, dynamic>) return null;

    final latitudeValue = latLngValue['latitude'];
    final longitudeValue = latLngValue['longitude'];
    final latitude = latitudeValue is num ? latitudeValue.toDouble() : null;
    final longitude = longitudeValue is num ? longitudeValue.toDouble() : null;

    if (latitude == null ||
        longitude == null ||
        !_isValidCoordinate(latitude, longitude)) {
      return null;
    }

    return (latitude, longitude);
  }
}

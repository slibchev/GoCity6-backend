import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Resolves a coordinate to a display-only address.
///
/// A missing result or any provider/network failure returns null so this
/// optional lookup cannot prevent ride creation. Callers should persist a
/// successful result and must not repeat this lookup during read requests.
class GoogleReverseGeocoder {
  GoogleReverseGeocoder({
    required this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 2),
  }) : client = client ?? http.Client() {
    if (apiKey.isEmpty) {
      throw ArgumentError.value(
        apiKey,
        'apiKey',
        'Google Maps API key cannot be empty.',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Timeout must be positive.',
      );
    }
  }

  final String apiKey;
  final http.Client client;
  final Duration timeout;

  Future<String?> resolve({
    required double latitude,
    required double longitude,
  }) async {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }

    try {
      final response = await client
          .get(
            Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
              'latlng': '$latitude,$longitude',
              'key': apiKey,
            }),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['status'] != 'OK') {
        return null;
      }

      final results = decoded['results'];
      if (results is! List || results.isEmpty || results.first is! Map) {
        return null;
      }

      final address = (results.first as Map)['formatted_address'];
      if (address is! String || address.trim().isEmpty) {
        return null;
      }

      return address.trim();
    } catch (_) {
      // Provider failures are non-fatal; drivers can use the GPS fallback.
      return null;
    }
  }
}

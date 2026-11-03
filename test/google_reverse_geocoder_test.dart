import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:gocity6_backend/routing/google_reverse_geocoder.dart';

void main() {
  test('resolves a GPS pair to the provider formatted address', () async {
    Uri? requestedUri;
    final geocoder = GoogleReverseGeocoder(
      apiKey: 'test-key',
      client: MockClient((request) async {
        requestedUri = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'status': 'OK',
              'results': [
                {'formatted_address': 'ул. Верила 2, 1408 София, България'},
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final address = await geocoder.resolve(
      latitude: 42.6977,
      longitude: 23.3219,
    );

    expect(address, 'ул. Верила 2, 1408 София, България');
    expect(requestedUri?.queryParameters['latlng'], '42.6977,23.3219');
  });

  test('returns null when Google has no reverse geocoding result', () async {
    final geocoder = GoogleReverseGeocoder(
      apiKey: 'test-key',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'status': 'ZERO_RESULTS', 'results': []}),
          200,
        ),
      ),
    );

    expect(
      await geocoder.resolve(latitude: 42.6977, longitude: 23.3219),
      isNull,
    );
  });

  test('provider and network errors are non-fatal', () async {
    final providerError = GoogleReverseGeocoder(
      apiKey: 'test-key',
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    final networkError = GoogleReverseGeocoder(
      apiKey: 'test-key',
      client: MockClient((_) async => throw const SocketException('offline')),
    );

    expect(
      await providerError.resolve(latitude: 42.6977, longitude: 23.3219),
      isNull,
    );
    expect(
      await networkError.resolve(latitude: 42.6977, longitude: 23.3219),
      isNull,
    );
  });

  test('timeout returns null instead of blocking ride creation', () async {
    final neverCompletes = Completer<http.Response>();
    final geocoder = GoogleReverseGeocoder(
      apiKey: 'test-key',
      timeout: const Duration(milliseconds: 5),
      client: MockClient((_) => neverCompletes.future),
    );

    expect(
      await geocoder.resolve(latitude: 42.6977, longitude: 23.3219),
      isNull,
    );
  });

  test('invalid coordinates do not issue a provider request', () async {
    var requestCount = 0;
    final geocoder = GoogleReverseGeocoder(
      apiKey: 'test-key',
      client: MockClient((_) async {
        requestCount++;
        return http.Response('{}', 200);
      }),
    );

    expect(await geocoder.resolve(latitude: 91, longitude: 23), isNull);
    expect(requestCount, 0);
  });
}

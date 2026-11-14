import 'dart:async';
import 'dart:convert';

import 'package:gocity6_backend/routing/google_route_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _routeResponse = {
  'routes': [
    {
      'distanceMeters': 12500,
      'duration': '900s',
      'polyline': {'encodedPolyline': 'encoded-route'},
      'legs': [
        {
          'startLocation': {
            'latLng': {'latitude': 42.7, 'longitude': 23.3},
          },
          'endLocation': {
            'latLng': {'latitude': 42.6, 'longitude': 23.4},
          },
        },
      ],
    },
  ],
};

Request _routeRequest({
  String pickup = 'Sofia Center',
  String destination = 'Sofia Airport',
  String? pickupPlaceId,
  String? destinationPlaceId,
  double? pickupLatitude,
  double? pickupLongitude,
}) {
  return Request(
    'POST',
    Uri.parse('http://localhost/route'),
    body: jsonEncode({
      'pickup': pickup,
      'destination': destination,
      'pickupPlaceId': ?pickupPlaceId,
      'destinationPlaceId': ?destinationPlaceId,
      'pickupLatitude': ?pickupLatitude,
      'pickupLongitude': ?pickupLongitude,
    }),
  );
}

Future<Response> _sendRoute(
  GoogleRouteApi api, {
  String pickup = 'Sofia Center',
  String destination = 'Sofia Airport',
  String? pickupPlaceId,
  String? destinationPlaceId,
  double? pickupLatitude,
  double? pickupLongitude,
}) {
  return api.handle(
    _routeRequest(
      pickup: pickup,
      destination: destination,
      pickupPlaceId: pickupPlaceId,
      destinationPlaceId: destinationPlaceId,
      pickupLatitude: pickupLatitude,
      pickupLongitude: pickupLongitude,
    ),
  );
}

Future<Object?> _responseJson(Response response) async =>
    jsonDecode(await response.readAsString());

void main() {
  test(
    'calculates a route after geocoding and preserves the response fields',
    () async {
      final requestedUris = <Uri>[];
      final client = MockClient((request) async {
        requestedUris.add(request.url);
        if (request.url.host == 'maps.googleapis.com') {
          return http.Response(
            jsonEncode({
              'status': 'OK',
              'results': [
                {
                  'geometry': {
                    'location': {'lat': 42.7, 'lng': 23.3},
                  },
                },
              ],
            }),
            200,
          );
        }
        expect(request.url.host, 'routes.googleapis.com');
        final sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        expect(sentBody['travelMode'], 'DRIVE');
        expect(sentBody['routingPreference'], 'TRAFFIC_AWARE');
        expect(sentBody['units'], 'METRIC');
        expect(
          request.headers['X-Goog-FieldMask'],
          contains('routes.polyline.encodedPolyline'),
        );
        return http.Response(jsonEncode(_routeResponse), 200);
      });
      final api = GoogleRouteApi(apiKey: 'test-key', client: client);

      final response = await _sendRoute(
        api,
        destinationPlaceId: 'destination-place',
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'application/json');
      expect(await _responseJson(response), {
        'distanceKm': 12.5,
        'durationMinutes': 15.0,
        'pickupLatitude': 42.7,
        'pickupLongitude': 23.3,
        'destinationLatitude': 42.6,
        'destinationLongitude': 23.4,
        'encodedPolyline': 'encoded-route',
      });
      expect(requestedUris, hasLength(2));
      expect(requestedUris.first.host, 'maps.googleapis.com');
      expect(requestedUris.first.queryParameters['address'], 'Sofia Center');
      expect(requestedUris.last.host, 'routes.googleapis.com');

      client.close();
    },
  );

  test('returns 504 and aborts a timed out geocoding request', () async {
    final abortObserved = Completer<void>();
    final client = MockClient.streaming((request, _) async {
      expect(request.url.host, 'maps.googleapis.com');
      final abortable = request as http.Abortable;
      await abortable.abortTrigger!;
      abortObserved.complete();
      throw http.RequestAbortedException(request.url);
    });
    final api = GoogleRouteApi(
      apiKey: 'test-key',
      client: client,
      timeout: const Duration(milliseconds: 30),
    );

    final response = await _sendRoute(api, destinationPlaceId: 'destination');

    expect(response.statusCode, 504);
    expect(await _responseJson(response), {
      'error': 'Route calculation timed out.',
    });
    await abortObserved.future.timeout(const Duration(seconds: 1));

    client.close();
  });

  test('returns 504 and aborts a timed out Google Routes request', () async {
    final abortObserved = Completer<void>();
    final client = MockClient.streaming((request, _) async {
      expect(request.url.host, 'routes.googleapis.com');
      final abortable = request as http.Abortable;
      await abortable.abortTrigger!;
      abortObserved.complete();
      throw http.RequestAbortedException(request.url);
    });
    final api = GoogleRouteApi(
      apiKey: 'test-key',
      client: client,
      timeout: const Duration(milliseconds: 30),
    );

    final response = await _sendRoute(
      api,
      pickupLatitude: 42.7,
      pickupLongitude: 23.3,
      destinationPlaceId: 'destination',
    );

    expect(response.statusCode, 504);
    expect(await _responseJson(response), {
      'error': 'Route calculation timed out.',
    });
    await abortObserved.future.timeout(const Duration(seconds: 1));

    client.close();
  });

  test('keeps provider errors as controlled 500 responses', () async {
    final geocodingClient = MockClient(
      (_) async => http.Response('unavailable', 503),
    );
    final geocodingApi = GoogleRouteApi(
      apiKey: 'test-key',
      client: geocodingClient,
    );

    final geocodingResponse = await _sendRoute(
      geocodingApi,
      destinationPlaceId: 'destination',
    );

    expect(geocodingResponse.statusCode, 500);
    expect(await _responseJson(geocodingResponse), {
      'error': 'Route calculation failed.',
    });
    geocodingClient.close();

    final routesClient = MockClient(
      (_) async => http.Response('unavailable', 503),
    );
    final routesApi = GoogleRouteApi(apiKey: 'test-key', client: routesClient);

    final routesResponse = await _sendRoute(
      routesApi,
      pickupLatitude: 42.7,
      pickupLongitude: 23.3,
      destinationPlaceId: 'destination',
    );

    expect(routesResponse.statusCode, 500);
    expect(await _responseJson(routesResponse), {
      'error': 'Route calculation failed.',
    });
    routesClient.close();
  });

  test('route validation keeps the existing 400 response', () async {
    final client = MockClient((_) async {
      fail('Invalid requests must not call Google.');
    });
    final api = GoogleRouteApi(apiKey: 'test-key', client: client);

    final response = await api.handle(
      Request('POST', Uri.parse('http://localhost/route'), body: '{}'),
    );

    expect(response.statusCode, 400);
    expect(await _responseJson(response), {
      'error': 'Pickup and destination are required.',
    });
    client.close();
  });
}

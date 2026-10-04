import 'dart:convert';

import 'package:gocity6_backend/routing/google_route_estimator.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'RouteWaypoint requires a complete locator',
    () {
      expect(
        () => RouteWaypoint(),
        throwsArgumentError,
      );

      expect(
        () => RouteWaypoint(latitude: 42.7),
        throwsArgumentError,
      );

      expect(
        () => RouteWaypoint(longitude: 23.3),
        throwsArgumentError,
      );
    },
  );

  test(
    'GoogleRouteEstimator uses live coordinates and geocodes address destination',
    () async {
      final requestedUris = <Uri>[];

      final client = MockClient((request) async {
        requestedUris.add(request.url);

        if (request.method == 'GET' &&
            request.url.host == 'maps.googleapis.com') {
          expect(
            request.url.queryParameters['address'],
            'Next pickup',
          );

          return http.Response(
            jsonEncode({
              'status': 'OK',
              'results': [
                {
                  'geometry': {
                    'location': {
                      'lat': 42.7000,
                      'lng': 23.3300,
                    },
                  },
                },
              ],
            }),
            200,
          );
        }

        if (request.method == 'POST' &&
            request.url.host == 'routes.googleapis.com') {
          final body =
              jsonDecode(request.body) as Map<String, dynamic>;

          final origin =
              body['origin'] as Map<String, dynamic>;
          final originLocation =
              origin['location'] as Map<String, dynamic>;
          final originLatLng =
              originLocation['latLng'] as Map<String, dynamic>;

          expect(originLatLng['latitude'], 42.6500);
          expect(originLatLng['longitude'], 23.3000);

          final destination =
              body['destination'] as Map<String, dynamic>;
          final destinationLocation =
              destination['location'] as Map<String, dynamic>;
          final destinationLatLng =
              destinationLocation['latLng']
                  as Map<String, dynamic>;

          expect(destinationLatLng['latitude'], 42.7000);
          expect(destinationLatLng['longitude'], 23.3300);

          return http.Response(
            jsonEncode({
              'routes': [
                {
                  'distanceMeters': 2450,
                  'duration': '378.5s',
                  'legs': [
                    {
                      'startLocation': {
                        'latLng': {
                          'latitude': 42.6501,
                          'longitude': 23.3001,
                        },
                      },
                      'endLocation': {
                        'latLng': {
                          'latitude': 42.6999,
                          'longitude': 23.3299,
                        },
                      },
                    },
                  ],
                  'polyline': {
                    'encodedPolyline': 'encoded-route',
                  },
                },
              ],
            }),
            200,
          );
        }

        return http.Response('not found', 404);
      });

      final estimator = GoogleRouteEstimator(
        apiKey: 'test-api-key',
        client: client,
      );

      final estimate = await estimator.estimate(
        origin: RouteWaypoint(
          latitude: 42.6500,
          longitude: 23.3000,
        ),
        destination: RouteWaypoint(
          address: 'Next pickup',
        ),
      );

      expect(estimate.distanceMeters, 2450);
      expect(estimate.durationSeconds, 378.5);
      expect(estimate.originLatitude, 42.6501);
      expect(estimate.originLongitude, 23.3001);
      expect(estimate.destinationLatitude, 42.6999);
      expect(estimate.destinationLongitude, 23.3299);
      expect(estimate.encodedPolyline, 'encoded-route');

      expect(requestedUris, hasLength(2));
    },
  );

  test(
    'GoogleRouteEstimator uses placeId without geocoding',
    () async {
      var geocodeCalled = false;

      final client = MockClient((request) async {
        if (request.method == 'GET') {
          geocodeCalled = true;

          return http.Response('unexpected geocode', 500);
        }

        final body =
            jsonDecode(request.body) as Map<String, dynamic>;

        expect(
          body['origin'],
          {'placeId': 'origin-place'},
        );

        expect(
          body['destination'],
          {'placeId': 'destination-place'},
        );

        return http.Response(
          jsonEncode({
            'routes': [
              {
                'distanceMeters': 1000,
                'duration': '120s',
                'legs': [
                  {
                    'startLocation': {
                      'latLng': {
                        'latitude': 42.1,
                        'longitude': 23.1,
                      },
                    },
                    'endLocation': {
                      'latLng': {
                        'latitude': 42.2,
                        'longitude': 23.2,
                      },
                    },
                  },
                ],
              },
            ],
          }),
          200,
        );
      });

      final estimator = GoogleRouteEstimator(
        apiKey: 'test-api-key',
        client: client,
      );

      final estimate = await estimator.estimate(
        origin: RouteWaypoint(
          placeId: 'origin-place',
        ),
        destination: RouteWaypoint(
          placeId: 'destination-place',
        ),
      );

      expect(geocodeCalled, isFalse);
      expect(estimate.distanceMeters, 1000);
      expect(estimate.durationSeconds, 120);
    },
  );

  test(
    'GoogleRouteEstimator treats missing distanceMeters as zero for zero-distance route',
    () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'routes': [
              {
                'legs': [
                  {
                    'startLocation': {
                      'latLng': {
                        'latitude': 42.696391,
                        'longitude': 23.3325317,
                      },
                    },
                    'endLocation': {
                      'latLng': {
                        'latitude': 42.696391,
                        'longitude': 23.3325317,
                      },
                    },
                  },
                ],
                'duration': '0s',
                'polyline': {
                  'encodedPolyline': 'mcrcGiclmC',
                },
              },
            ],
          }),
          200,
        );
      });

      final estimator = GoogleRouteEstimator(
        apiKey: 'test-api-key',
        client: client,
      );

      final estimate = await estimator.estimate(
        origin: RouteWaypoint(
          latitude: 42.696100,
          longitude: 23.332200,
        ),
        destination: RouteWaypoint(
          latitude: 42.696391,
          longitude: 23.3325317,
        ),
      );

      expect(estimate.distanceMeters, 0);
      expect(estimate.durationSeconds, 0);
      expect(estimate.originLatitude, 42.696391);
      expect(estimate.originLongitude, 23.3325317);
      expect(estimate.destinationLatitude, 42.696391);
      expect(estimate.destinationLongitude, 23.3325317);
      expect(estimate.encodedPolyline, 'mcrcGiclmC');
    },
  );
  test(
    'GoogleRouteEstimator rejects empty route results',
    () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'routes': <Object>[],
          }),
          200,
        );
      });

      final estimator = GoogleRouteEstimator(
        apiKey: 'test-api-key',
        client: client,
      );

      expect(
        () => estimator.estimate(
          origin: RouteWaypoint(
            latitude: 42.1,
            longitude: 23.1,
          ),
          destination: RouteWaypoint(
            latitude: 42.2,
            longitude: 23.2,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );
}

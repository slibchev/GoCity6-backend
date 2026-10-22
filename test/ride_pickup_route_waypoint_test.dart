import 'package:gocity6_backend/ride/ride_pickup_route_waypoint.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

void main() {
  RideRequest ride({
    required String pickup,
    double? latitude,
    double? longitude,
  }) => RideRequest(
    id: 'ride-1',
    pickup: pickup,
    pickupLatitude: latitude,
    pickupLongitude: longitude,
    destination: 'Airport',
    passengers: 1,
    requestedAt: DateTime.utc(2026),
  );

  test('uses stored coordinates instead of pickup label', () {
    final waypoint = ridePickupRouteWaypoint(
      ride(pickup: 'Моето местоположение', latitude: 42.7, longitude: 23.3),
    );

    expect(waypoint.latitude, 42.7);
    expect(waypoint.longitude, 23.3);
    expect(waypoint.address, isNull);
  });

  test('keeps address-only behavior for legacy ordinary pickup text', () {
    final waypoint = ridePickupRouteWaypoint(ride(pickup: 'Sofia Center'));

    expect(waypoint.address, 'Sofia Center');
  });

  test('safely rejects legacy current-location labels without coordinates', () {
    for (final label in ['Моето местоположение', 'My location']) {
      expect(
        () => ridePickupRouteWaypoint(ride(pickup: label)),
        throwsA(
          isA<RouteWaypointResolutionException>().having(
            (error) => error.reason,
            'reason',
            RouteWaypointFailureReason.invalidCoordinates,
          ),
        ),
      );
    }
  });

  test('rejects malformed stored coordinate pairs', () {
    expect(
      () => ridePickupRouteWaypoint(
        ride(pickup: 'Pickup', latitude: 91, longitude: 23),
      ),
      throwsA(isA<RouteWaypointResolutionException>()),
    );
  });
}

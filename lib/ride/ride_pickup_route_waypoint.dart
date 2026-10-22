import '../routing/route_estimator.dart';
import 'ride_pickup_coordinates.dart';
import 'ride_request.dart';

/// Resolves a stored ride pickup for routing, preferring its GPS location.
///
/// Legacy current-location labels without coordinates cannot be geocoded
/// safely, so they fail with the typed, address-free routing exception.
RouteWaypoint ridePickupRouteWaypoint(RideRequest ride) {
  final latitude = ride.pickupLatitude;
  final longitude = ride.pickupLongitude;

  if ((latitude == null) != (longitude == null)) {
    throw const RouteWaypointResolutionException(
      RouteWaypointFailureReason.invalidCoordinates,
    );
  }

  if (latitude != null && longitude != null) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const RouteWaypointResolutionException(
        RouteWaypointFailureReason.invalidCoordinates,
      );
    }

    return RouteWaypoint(latitude: latitude, longitude: longitude);
  }

  if (isCurrentLocationPickupLabel(ride.pickup)) {
    throw const RouteWaypointResolutionException(
      RouteWaypointFailureReason.invalidCoordinates,
    );
  }

  return RouteWaypoint(address: ride.pickup);
}

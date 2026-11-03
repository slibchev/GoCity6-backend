import 'ride_request.dart';

/// Pickup details intended only for authenticated Driver API ride payloads.
Map<String, Object?> driverRidePickupJson(RideRequest ride) => {
  'pickupDisplayAddress': ride.pickupDisplayAddress,
  'pickupLatitude': ride.pickupLatitude,
  'pickupLongitude': ride.pickupLongitude,
};

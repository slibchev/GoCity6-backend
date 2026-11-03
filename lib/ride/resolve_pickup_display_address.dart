import 'ride_pickup_coordinates.dart';

/// Performs the optional reverse lookup only for a current-location pickup.
///
/// The caller persists this result with the new ride. A lookup failure is a
/// display fallback and must not affect the ride's GPS coordinates or creation.
Future<String?> resolvePickupDisplayAddress({
  required String pickup,
  required RidePickupCoordinates? coordinates,
  required Future<String?> Function({
    required double latitude,
    required double longitude,
  })?
  reverseGeocode,
}) async {
  if (coordinates == null ||
      !isCurrentLocationPickupLabel(pickup) ||
      reverseGeocode == null) {
    return null;
  }

  try {
    return await reverseGeocode(
      latitude: coordinates.latitude,
      longitude: coordinates.longitude,
    );
  } catch (_) {
    return null;
  }
}

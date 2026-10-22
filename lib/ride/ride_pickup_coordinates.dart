/// The validated WGS84 coordinate pair sent with a ride request.
class RidePickupCoordinates {
  final double latitude;
  final double longitude;

  const RidePickupCoordinates({
    required this.latitude,
    required this.longitude,
  });

  static RidePickupCoordinates? parseJson(Map<String, dynamic> body) {
    final hasLatitude = body.containsKey('pickupLatitude');
    final hasLongitude = body.containsKey('pickupLongitude');
    final latitudeValue = body['pickupLatitude'];
    final longitudeValue = body['pickupLongitude'];

    if (!hasLatitude && !hasLongitude) {
      return null;
    }

    if (!hasLatitude || !hasLongitude) {
      throw const InvalidRidePickupCoordinatesException();
    }

    if (latitudeValue == null && longitudeValue == null) {
      return null;
    }

    if (latitudeValue is! num || longitudeValue is! num) {
      throw const InvalidRidePickupCoordinatesException();
    }

    final latitude = latitudeValue.toDouble();
    final longitude = longitudeValue.toDouble();

    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const InvalidRidePickupCoordinatesException();
    }

    return RidePickupCoordinates(latitude: latitude, longitude: longitude);
  }
}

class InvalidRidePickupCoordinatesException implements Exception {
  const InvalidRidePickupCoordinatesException();
}

bool isCurrentLocationPickupLabel(String pickup) {
  final normalized = pickup.trim().toLowerCase();
  return normalized == 'моето местоположение' || normalized == 'my location';
}

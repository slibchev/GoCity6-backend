/// A validated WGS84 destination coordinate pair from a ride submission.
class RideDestinationCoordinates {
  final double latitude;
  final double longitude;

  const RideDestinationCoordinates({
    required this.latitude,
    required this.longitude,
  });

  static RideDestinationCoordinates? parseJson(Map<String, dynamic> body) {
    final hasLatitude = body.containsKey('destinationLatitude');
    final hasLongitude = body.containsKey('destinationLongitude');
    final latitudeValue = body['destinationLatitude'];
    final longitudeValue = body['destinationLongitude'];

    if (!hasLatitude && !hasLongitude) {
      return null;
    }

    if (!hasLatitude || !hasLongitude) {
      throw const InvalidRideDestinationCoordinatesException();
    }

    if (latitudeValue == null && longitudeValue == null) {
      return null;
    }

    if (latitudeValue is! num || longitudeValue is! num) {
      throw const InvalidRideDestinationCoordinatesException();
    }

    final latitude = latitudeValue.toDouble();
    final longitude = longitudeValue.toDouble();

    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const InvalidRideDestinationCoordinatesException();
    }

    return RideDestinationCoordinates(latitude: latitude, longitude: longitude);
  }
}

class InvalidRideDestinationCoordinatesException implements Exception {
  const InvalidRideDestinationCoordinatesException();
}

class RouteWaypoint {
  final String? address;
  final String? placeId;
  final double? latitude;
  final double? longitude;

  RouteWaypoint({
    this.address,
    this.placeId,
    this.latitude,
    this.longitude,
  }) {
    final hasLatitude = latitude != null;
    final hasLongitude = longitude != null;

    if (hasLatitude != hasLongitude) {
      throw ArgumentError(
        'Route waypoint latitude and longitude must be provided together.',
      );
    }

    final hasCoordinates = hasLatitude && hasLongitude;
    final hasPlaceId = placeId != null && placeId!.trim().isNotEmpty;
    final hasAddress = address != null && address!.trim().isNotEmpty;

    if (!hasCoordinates && !hasPlaceId && !hasAddress) {
      throw ArgumentError(
        'Route waypoint requires coordinates, placeId, or address.',
      );
    }
  }
}

class RouteEstimate {
  final double distanceMeters;
  final double durationSeconds;

  final double? originLatitude;
  final double? originLongitude;
  final double? destinationLatitude;
  final double? destinationLongitude;

  final String? encodedPolyline;

  RouteEstimate({
    required this.distanceMeters,
    required this.durationSeconds,
    this.originLatitude,
    this.originLongitude,
    this.destinationLatitude,
    this.destinationLongitude,
    this.encodedPolyline,
  }) {
    if (distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'Route distance cannot be negative.',
      );
    }

    if (durationSeconds < 0) {
      throw ArgumentError.value(
        durationSeconds,
        'durationSeconds',
        'Route duration cannot be negative.',
      );
    }
  }
}

abstract interface class RouteEstimator {
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  });
}

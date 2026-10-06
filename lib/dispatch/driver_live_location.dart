class DriverLiveLocation {
  final String driverId;
  final double latitude;
  final double longitude;
  final DateTime updatedAt;

  DriverLiveLocation({
    required this.driverId,
    required this.latitude,
    required this.longitude,
    required this.updatedAt,
  }) {
    if (driverId.trim().isEmpty) {
      throw ArgumentError.value(
        driverId,
        'driverId',
        'Driver ID cannot be empty.',
      );
    }

    if (latitude < -90 || latitude > 90) {
      throw ArgumentError.value(
        latitude,
        'latitude',
        'Latitude must be between -90 and 90.',
      );
    }

    if (longitude < -180 || longitude > 180) {
      throw ArgumentError.value(
        longitude,
        'longitude',
        'Longitude must be between -180 and 180.',
      );
    }
  }
}
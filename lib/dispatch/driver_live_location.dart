class DriverLiveLocation {
  static const Duration maximumReliableAge = Duration(seconds: 30);

  final String driverId;
  final double latitude;
  final double longitude;
  final DateTime updatedAt;

  /// Timestamp reported for the actual device GPS fix, if available.
  /// [updatedAt] remains the Backend receipt time used by existing freshness
  /// and display behavior.
  final DateTime? gpsFixAt;

  bool isReliableAt(DateTime now, {Duration maximumAge = maximumReliableAge}) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return false;
    }

    final receivedAge = now.toUtc().difference(updatedAt.toUtc());
    final fixAt = gpsFixAt?.toUtc();
    if (receivedAge.isNegative || receivedAge > maximumAge || fixAt == null) {
      return false;
    }

    final fixAge = now.toUtc().difference(fixAt);
    return !fixAge.isNegative && fixAge <= maximumAge;
  }

  DriverLiveLocation({
    required this.driverId,
    required this.latitude,
    required this.longitude,
    required this.updatedAt,
    this.gpsFixAt,
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

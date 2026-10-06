import 'driver_live_location.dart';

abstract interface class DriverLiveLocationRepository {
  Future<DriverLiveLocation?> findByDriverId(String driverId);

  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  });
}
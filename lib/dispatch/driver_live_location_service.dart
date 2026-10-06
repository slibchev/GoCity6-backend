import 'driver_live_location.dart';
import 'driver_live_location_repository.dart';

class DriverLiveLocationService {
  final DriverLiveLocationRepository repository;

  const DriverLiveLocationService({
    required this.repository,
  });

  Future<DriverLiveLocation> update({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime now,
  }) {
    return repository.save(
      driverId: driverId,
      latitude: latitude,
      longitude: longitude,
      updatedAt: now.toUtc(),
    );
  }

  Future<DriverLiveLocation?> get({
    required String driverId,
  }) {
    return repository.findByDriverId(driverId);
  }
}
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_service.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 6, 20);

  test('updates driver live location through repository', () async {
    final repository = _FakeDriverLiveLocationRepository();

    final service = DriverLiveLocationService(
      repository: repository,
    );

    final result = await service.update(
      driverId: 'driver-001',
      latitude: 42.6977,
      longitude: 23.3219,
      now: now,
    );

    expect(result.driverId, 'driver-001');
    expect(result.latitude, 42.6977);
    expect(result.longitude, 23.3219);
    expect(result.updatedAt, now);

    expect(repository.saveCalls, 1);
  });

  test('loads driver live location through repository', () async {
    final location = DriverLiveLocation(
      driverId: 'driver-001',
      latitude: 42.6977,
      longitude: 23.3219,
      updatedAt: now,
    );

    final repository = _FakeDriverLiveLocationRepository(
      location: location,
    );

    final service = DriverLiveLocationService(
      repository: repository,
    );

    final result = await service.get(
      driverId: 'driver-001',
    );

    expect(result, same(location));
    expect(repository.findCalls, 1);
  });
}

class _FakeDriverLiveLocationRepository
    implements DriverLiveLocationRepository {
  _FakeDriverLiveLocationRepository({
    this.location,
  });

  DriverLiveLocation? location;

  int saveCalls = 0;
  int findCalls = 0;

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async {
    findCalls += 1;
    return location;
  }

  @override
  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  }) async {
    saveCalls += 1;

    final saved = DriverLiveLocation(
      driverId: driverId,
      latitude: latitude,
      longitude: longitude,
      updatedAt: updatedAt,
    );

    location = saved;
    return saved;
  }
}
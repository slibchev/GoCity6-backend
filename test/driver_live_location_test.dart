import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:test/test.dart';

void main() {
  final updatedAt = DateTime.utc(2026, 10, 6, 20);

  test('creates valid driver live location', () {
    final location = DriverLiveLocation(
      driverId: 'driver-001',
      latitude: 42.6977,
      longitude: 23.3219,
      updatedAt: updatedAt,
    );

    expect(location.driverId, 'driver-001');
    expect(location.latitude, 42.6977);
    expect(location.longitude, 23.3219);
    expect(location.updatedAt, updatedAt);
  });

  test('rejects invalid latitude', () {
    expect(
      () => DriverLiveLocation(
        driverId: 'driver-001',
        latitude: 91,
        longitude: 23.3219,
        updatedAt: updatedAt,
      ),
      throwsArgumentError,
    );
  });

  test('rejects invalid longitude', () {
    expect(
      () => DriverLiveLocation(
        driverId: 'driver-001',
        latitude: 42.6977,
        longitude: 181,
        updatedAt: updatedAt,
      ),
      throwsArgumentError,
    );
  });

  test('rejects empty driver id', () {
    expect(
      () => DriverLiveLocation(
        driverId: '   ',
        latitude: 42.6977,
        longitude: 23.3219,
        updatedAt: updatedAt,
      ),
      throwsArgumentError,
    );
  });
}
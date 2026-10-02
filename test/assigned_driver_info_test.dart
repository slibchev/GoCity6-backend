import 'package:gocity6_backend/ride/assigned_driver_info.dart';
import 'package:test/test.dart';

void main() {
  test('AssignedDriverInfo serializes passenger presentation data', () {
    const info = AssignedDriverInfo(
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      name: 'Иван Иванов',
      phoneNumber: '+359888123456',
      licensePlate: 'CA1234AB',
    );

    expect(info.toJson(), {
      'driverId': 'driver-001',
      'vehicleId': 'vehicle-001',
      'name': 'Иван Иванов',
      'phoneNumber': '+359888123456',
      'licensePlate': 'CA1234AB',
    });
  });
}

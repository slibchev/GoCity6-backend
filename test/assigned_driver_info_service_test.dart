import 'package:gocity6_backend/ride/assigned_driver_info.dart';
import 'package:gocity6_backend/ride/assigned_driver_info_repository.dart';
import 'package:gocity6_backend/ride/assigned_driver_info_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:test/test.dart';

void main() {
  test('does not look up driver info when ride has no assignment', () async {
    final repository = _FakeAssignedDriverInfoRepository();

    final ride = RideRequest(
      id: 'ride-001',
      pickup: 'Pickup',
      destination: 'Destination',
      passengers: 1,
      requestedAt: DateTime.utc(2026, 10, 2),
      status: RideRequestStatus.reserved,
    );

    final service = AssignedDriverInfoService(repository: repository);

    final result = await service.findForRide(ride);

    expect(result, isNull);
    expect(repository.callCount, 0);
  });

  test('looks up driver info using exact ride assignment', () async {
    const expectedInfo = AssignedDriverInfo(
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      name: 'Иван Иванов',
      phoneNumber: '+359888123456',
      licensePlate: 'CA1234AB',
    );

    final repository = _FakeAssignedDriverInfoRepository(result: expectedInfo);

    final ride = RideRequest(
      id: 'ride-002',
      pickup: 'Pickup',
      destination: 'Destination',
      passengers: 1,
      requestedAt: DateTime.utc(2026, 10, 2),
      status: RideRequestStatus.accepted,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final service = AssignedDriverInfoService(repository: repository);

    final result = await service.findForRide(ride);

    expect(result, same(expectedInfo));
    expect(repository.callCount, 1);
    expect(repository.lastDriverId, 'driver-001');
    expect(repository.lastVehicleId, 'vehicle-001');
  });
}

class _FakeAssignedDriverInfoRepository
    implements AssignedDriverInfoRepository {
  final AssignedDriverInfo? result;

  int callCount = 0;
  String? lastDriverId;
  String? lastVehicleId;

  _FakeAssignedDriverInfoRepository({this.result});

  @override
  Future<AssignedDriverInfo?> findByAssignment({
    required String driverId,
    required String vehicleId,
  }) async {
    callCount += 1;
    lastDriverId = driverId;
    lastVehicleId = vehicleId;

    return result;
  }
}

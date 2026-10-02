import 'assigned_driver_info.dart';

abstract interface class AssignedDriverInfoRepository {
  Future<AssignedDriverInfo?> findByAssignment({
    required String driverId,
    required String vehicleId,
  });
}

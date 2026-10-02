import 'assigned_driver_info.dart';
import 'assigned_driver_info_repository.dart';
import 'ride_request.dart';

class AssignedDriverInfoService {
  final AssignedDriverInfoRepository repository;

  const AssignedDriverInfoService({required this.repository});

  Future<AssignedDriverInfo?> findForRide(RideRequest ride) {
    final driverId = ride.assignedDriverId;
    final vehicleId = ride.assignedVehicleId;

    if (driverId == null || vehicleId == null) {
      return Future.value(null);
    }

    return repository.findByAssignment(
      driverId: driverId,
      vehicleId: vehicleId,
    );
  }
}

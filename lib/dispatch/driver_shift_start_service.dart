import 'active_driver_shift.dart';
import 'driver_assigned_vehicle_repository.dart';
import 'driver_shift_repository.dart';

enum DriverShiftStartFailure {
  noAssignedVehicle,
  assignedVehicleInactive,
}

class DriverShiftStartException implements Exception {
  final DriverShiftStartFailure failure;

  const DriverShiftStartException(this.failure);

  @override
  String toString() {
    return 'Driver shift start failed: ${failure.name}';
  }
}

class DriverShiftStartService {
  final DriverShiftRepository shiftRepository;
  final DriverAssignedVehicleRepository assignedVehicleRepository;
  final String Function() shiftIdFactory;
  final DateTime Function() now;

  const DriverShiftStartService({
    required this.shiftRepository,
    required this.assignedVehicleRepository,
    required this.shiftIdFactory,
    required this.now,
  });

  Future<ActiveDriverShift> start({
    required String driverId,
  }) async {
    final existingShift =
        await shiftRepository.findActiveByDriverId(driverId);

    if (existingShift != null) {
      return existingShift;
    }

    final vehicle =
        await assignedVehicleRepository.findByDriverId(driverId);

    if (vehicle == null) {
      throw const DriverShiftStartException(
        DriverShiftStartFailure.noAssignedVehicle,
      );
    }

    if (!vehicle.isActive) {
      throw const DriverShiftStartException(
        DriverShiftStartFailure.assignedVehicleInactive,
      );
    }

    return shiftRepository.startShift(
      shiftId: shiftIdFactory(),
      driverId: driverId,
      vehicleId: vehicle.id,
      startedAt: now(),
    );
  }
}
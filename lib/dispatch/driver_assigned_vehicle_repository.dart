class DriverAssignedVehicle {
  final String id;
  final String plateNumber;
  final bool isActive;

  const DriverAssignedVehicle({
    required this.id,
    required this.plateNumber,
    required this.isActive,
  });
}

abstract interface class DriverAssignedVehicleRepository {
  Future<DriverAssignedVehicle?> findByDriverId(String driverId);
}
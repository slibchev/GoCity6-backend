class AssignedDriverInfo {
  final String driverId;
  final String vehicleId;
  final String name;
  final String phoneNumber;
  final String licensePlate;

  const AssignedDriverInfo({
    required this.driverId,
    required this.vehicleId,
    required this.name,
    required this.phoneNumber,
    required this.licensePlate,
  });

  Map<String, dynamic> toJson() {
    return {
      'driverId': driverId,
      'vehicleId': vehicleId,
      'name': name,
      'phoneNumber': phoneNumber,
      'licensePlate': licensePlate,
    };
  }
}

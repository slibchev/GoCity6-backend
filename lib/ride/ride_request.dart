import 'ride_request_status.dart';

const Object _notProvided = Object();

class RideRequest {
  final String id;

  final String pickup;
  final String destination;

  final int passengers;
  final bool hasLuggage;

  final DateTime requestedAt;
  final RideRequestStatus status;

  final String? assignedDriverId;
  final String? assignedVehicleId;

  final String? completedByDriverId;
  final DateTime? completedAt;

  const RideRequest({
    required this.id,
    required this.pickup,
    required this.destination,
    required this.passengers,
    this.hasLuggage = false,
    required this.requestedAt,
    this.status = RideRequestStatus.pending,
    this.assignedDriverId,
    this.assignedVehicleId,
    this.completedByDriverId,
    this.completedAt,
  });

  RideRequest copyWith({
    String? id,
    String? pickup,
    String? destination,
    int? passengers,
    bool? hasLuggage,
    DateTime? requestedAt,
    RideRequestStatus? status,
    Object? assignedDriverId = _notProvided,
    Object? assignedVehicleId = _notProvided,
    Object? completedByDriverId = _notProvided,
    Object? completedAt = _notProvided,
  }) {
    return RideRequest(
      id: id ?? this.id,
      pickup: pickup ?? this.pickup,
      destination: destination ?? this.destination,
      passengers: passengers ?? this.passengers,
      hasLuggage: hasLuggage ?? this.hasLuggage,
      requestedAt: requestedAt ?? this.requestedAt,
      status: status ?? this.status,
      assignedDriverId: identical(assignedDriverId, _notProvided)
          ? this.assignedDriverId
          : assignedDriverId as String?,
      assignedVehicleId: identical(assignedVehicleId, _notProvided)
          ? this.assignedVehicleId
          : assignedVehicleId as String?,
      completedByDriverId: identical(completedByDriverId, _notProvided)
          ? this.completedByDriverId
          : completedByDriverId as String?,
      completedAt: identical(completedAt, _notProvided)
          ? this.completedAt
          : completedAt as DateTime?,
    );
  }
}

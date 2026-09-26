import 'ride_money.dart';
import 'ride_request_status.dart';
import 'ride_state_machine.dart';

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

  final String currency;
  final int? meterFareMinor;
  final int? commissionRateBps;
  final int? commissionAmountMinor;

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
    this.currency = RideMoney.currency,
    this.meterFareMinor,
    this.commissionRateBps,
    this.commissionAmountMinor,
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
    Object? assignedDriverId = _notProvided,
    Object? assignedVehicleId = _notProvided,
    String? currency,
    Object? meterFareMinor = _notProvided,
    Object? commissionRateBps = _notProvided,
    Object? commissionAmountMinor = _notProvided,
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
      status: status,
      assignedDriverId: identical(assignedDriverId, _notProvided)
          ? this.assignedDriverId
          : assignedDriverId as String?,
      assignedVehicleId: identical(assignedVehicleId, _notProvided)
          ? this.assignedVehicleId
          : assignedVehicleId as String?,
      currency: currency ?? this.currency,
      meterFareMinor: identical(meterFareMinor, _notProvided)
          ? this.meterFareMinor
          : meterFareMinor as int?,
      commissionRateBps: identical(commissionRateBps, _notProvided)
          ? this.commissionRateBps
          : commissionRateBps as int?,
      commissionAmountMinor: identical(commissionAmountMinor, _notProvided)
          ? this.commissionAmountMinor
          : commissionAmountMinor as int?,
      completedByDriverId: identical(completedByDriverId, _notProvided)
          ? this.completedByDriverId
          : completedByDriverId as String?,
      completedAt: identical(completedAt, _notProvided)
          ? this.completedAt
          : completedAt as DateTime?,
    );
  }

  RideRequest transitionTo(RideRequestStatus newStatus) {
    RideStateMachine.validateTransition(from: status, to: newStatus);

    return RideRequest(
      id: id,
      pickup: pickup,
      destination: destination,
      passengers: passengers,
      hasLuggage: hasLuggage,
      requestedAt: requestedAt,
      status: newStatus,
      assignedDriverId: assignedDriverId,
      assignedVehicleId: assignedVehicleId,
      currency: currency,
      meterFareMinor: meterFareMinor,
      commissionRateBps: commissionRateBps,
      commissionAmountMinor: commissionAmountMinor,
      completedByDriverId: completedByDriverId,
      completedAt: completedAt,
    );
  }
}

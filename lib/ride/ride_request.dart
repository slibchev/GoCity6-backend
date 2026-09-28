import 'ride_money.dart';
import 'ride_request_status.dart';
import 'ride_state_machine.dart';

const Object _notProvided = Object();

enum RideBonusDecision {
  notOffered,
  awaitingCustomer,
  accepted,
  declined;

  String get databaseValue {
    switch (this) {
      case RideBonusDecision.notOffered:
        return 'not_offered';
      case RideBonusDecision.awaitingCustomer:
        return 'awaiting_customer';
      case RideBonusDecision.accepted:
        return 'accepted';
      case RideBonusDecision.declined:
        return 'declined';
    }
  }

  static RideBonusDecision fromDatabaseValue(String value) {
    switch (value) {
      case 'not_offered':
        return RideBonusDecision.notOffered;
      case 'awaiting_customer':
        return RideBonusDecision.awaitingCustomer;
      case 'accepted':
        return RideBonusDecision.accepted;
      case 'declined':
        return RideBonusDecision.declined;
      default:
        throw ArgumentError.value(
          value,
          'value',
          'Unknown ride bonus decision.',
        );
    }
  }
}

class RideRequest {
  static const int normalDispatchRound = 1;
  static const int bonusDispatchRound = 2;

  static const int noDriverBonusMinor = 0;
  static const int driverBonusFiveEuroMinor = 500;

  final String id;

  final String pickup;
  final String destination;

  final int passengers;
  final bool hasLuggage;

  final DateTime requestedAt;
  final RideRequestStatus status;

  final String? assignedDriverId;
  final String? assignedVehicleId;

  final int dispatchRound;
  final int driverBonusMinor;
  final RideBonusDecision bonusDecision;

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
    this.dispatchRound = normalDispatchRound,
    this.driverBonusMinor = noDriverBonusMinor,
    this.bonusDecision = RideBonusDecision.notOffered,
    this.currency = RideMoney.currency,
    this.meterFareMinor,
    this.commissionRateBps,
    this.commissionAmountMinor,
    this.completedByDriverId,
    this.completedAt,
  }) : assert(
         dispatchRound == normalDispatchRound ||
             dispatchRound == bonusDispatchRound,
       ),
       assert(
         driverBonusMinor == noDriverBonusMinor ||
             driverBonusMinor == driverBonusFiveEuroMinor,
       ),
       assert(
         (dispatchRound == normalDispatchRound &&
                 driverBonusMinor == noDriverBonusMinor &&
                 bonusDecision != RideBonusDecision.accepted) ||
             (dispatchRound == bonusDispatchRound &&
                 driverBonusMinor == driverBonusFiveEuroMinor &&
                 bonusDecision == RideBonusDecision.accepted),
       );

  RideRequest copyWith({
    String? id,
    String? pickup,
    String? destination,
    int? passengers,
    bool? hasLuggage,
    DateTime? requestedAt,
    Object? assignedDriverId = _notProvided,
    Object? assignedVehicleId = _notProvided,
    int? dispatchRound,
    int? driverBonusMinor,
    RideBonusDecision? bonusDecision,
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
      dispatchRound: dispatchRound ?? this.dispatchRound,
      driverBonusMinor: driverBonusMinor ?? this.driverBonusMinor,
      bonusDecision: bonusDecision ?? this.bonusDecision,
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
      dispatchRound: dispatchRound,
      driverBonusMinor: driverBonusMinor,
      bonusDecision: bonusDecision,
      currency: currency,
      meterFareMinor: meterFareMinor,
      commissionRateBps: commissionRateBps,
      commissionAmountMinor: commissionAmountMinor,
      completedByDriverId: completedByDriverId,
      completedAt: completedAt,
    );
  }
}

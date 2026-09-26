import 'ride_request_status.dart';

class RideStateTransitionException implements Exception {
  final RideRequestStatus from;
  final RideRequestStatus to;

  const RideStateTransitionException({required this.from, required this.to});

  @override
  String toString() {
    return 'Invalid ride status transition: ${from.name} -> ${to.name}';
  }
}

class RideStateMachine {
  const RideStateMachine._();

  static const Map<RideRequestStatus, Set<RideRequestStatus>>
  _allowedTransitions = {
    RideRequestStatus.pending: {
      RideRequestStatus.waitingForVehicle,
      RideRequestStatus.accepted,
      RideRequestStatus.cancelled,
    },

    RideRequestStatus.waitingForVehicle: {
      RideRequestStatus.reserved,
      RideRequestStatus.accepted,
      RideRequestStatus.cancelled,
    },

    RideRequestStatus.reserved: {
      RideRequestStatus.accepted,
      RideRequestStatus.waitingForVehicle,
      RideRequestStatus.cancelled,
    },

    RideRequestStatus.accepted: {
      RideRequestStatus.driverArriving,
      RideRequestStatus.cancelled,
    },

    RideRequestStatus.driverArriving: {
      RideRequestStatus.inProgress,
      RideRequestStatus.cancelled,
    },

    RideRequestStatus.inProgress: {RideRequestStatus.completed},

    RideRequestStatus.completed: {},
    RideRequestStatus.cancelled: {},
  };

  static bool canTransition({
    required RideRequestStatus from,
    required RideRequestStatus to,
  }) {
    return _allowedTransitions[from]!.contains(to);
  }

  static void validateTransition({
    required RideRequestStatus from,
    required RideRequestStatus to,
  }) {
    if (!canTransition(from: from, to: to)) {
      throw RideStateTransitionException(from: from, to: to);
    }
  }

  static Set<RideRequestStatus> allowedTransitionsFrom(
    RideRequestStatus status,
  ) {
    return Set.unmodifiable(_allowedTransitions[status]!);
  }
}

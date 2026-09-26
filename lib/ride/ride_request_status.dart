enum RideRequestStatus {
  pending,
  accepted,
  driverArriving,
  inProgress,
  completed,
  cancelled,
  waitingForVehicle,
  reserved,
}

extension RideRequestStatusX on RideRequestStatus {
  bool get isTerminal {
    return this == RideRequestStatus.completed ||
        this == RideRequestStatus.cancelled;
  }

  bool get canBeCancelled {
    switch (this) {
      case RideRequestStatus.pending:
      case RideRequestStatus.waitingForVehicle:
      case RideRequestStatus.reserved:
      case RideRequestStatus.accepted:
      case RideRequestStatus.driverArriving:
        return true;

      case RideRequestStatus.inProgress:
      case RideRequestStatus.completed:
      case RideRequestStatus.cancelled:
        return false;
    }
  }
}

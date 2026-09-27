class DispatchCandidate {
  final String driverId;
  final String vehicleId;

  final int etaSeconds;
  final int distanceMeters;

  final DateTime queuePrioritySince;

  final bool hasCustomerCancellationPriority;

  DispatchCandidate({
    required this.driverId,
    required this.vehicleId,
    required this.etaSeconds,
    required this.distanceMeters,
    required this.queuePrioritySince,
    this.hasCustomerCancellationPriority = false,
  }) {
    if (etaSeconds < 0) {
      throw ArgumentError.value(
        etaSeconds,
        'etaSeconds',
        'ETA cannot be negative.',
      );
    }

    if (distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'Distance cannot be negative.',
      );
    }
  }
}

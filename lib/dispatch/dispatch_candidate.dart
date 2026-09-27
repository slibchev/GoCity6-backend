import 'driver_queue_state.dart';

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

  static DispatchCandidate? fromQueueState({
    required DriverQueueState queueState,
    required String vehicleId,
    required int etaSeconds,
    required int distanceMeters,
    required DateTime now,
    bool hasCustomerCancellationPriority = false,
  }) {
    final effectiveState = queueState.effectiveAt(now);

    if (effectiveState.availability != DriverQueueAvailability.available ||
        effectiveState.hasPendingOffer) {
      return null;
    }

    return DispatchCandidate(
      driverId: effectiveState.driverId,
      vehicleId: vehicleId,
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      queuePrioritySince: effectiveState.queuePrioritySince,
      hasCustomerCancellationPriority: hasCustomerCancellationPriority,
    );
  }
}

import 'driver_queue_state.dart';

class ActiveDriverShift {
  final String id;
  final String driverId;
  final String vehicleId;
  final DateTime startedAt;
  final DriverQueueState queueState;

  const ActiveDriverShift._({
    required this.id,
    required this.driverId,
    required this.vehicleId,
    required this.startedAt,
    required this.queueState,
  });

  factory ActiveDriverShift.restore({
    required String id,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
    required DriverQueueState queueState,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Shift id cannot be empty.');
    }

    if (driverId.isEmpty) {
      throw ArgumentError.value(
        driverId,
        'driverId',
        'Driver id cannot be empty.',
      );
    }

    if (vehicleId.isEmpty) {
      throw ArgumentError.value(
        vehicleId,
        'vehicleId',
        'Vehicle id cannot be empty.',
      );
    }

    if (queueState.driverId != driverId) {
      throw ArgumentError('Queue state driver must match shift driver.');
    }

    return ActiveDriverShift._(
      id: id,
      driverId: driverId,
      vehicleId: vehicleId,
      startedAt: startedAt,
      queueState: queueState,
    );
  }
}

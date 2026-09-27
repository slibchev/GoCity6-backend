import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:test/test.dart';

void main() {
  final startedAt = DateTime.utc(2026, 9, 27, 18);

  test('restores active driver shift', () {
    final queueState = DriverQueueState.restore(
      driverId: 'driver-001',
      queuePrioritySince: startedAt,
      availability: DriverQueueAvailability.available,
      shortBreaksUsed: 1,
      breakStartedAt: null,
      hasPendingOffer: false,
    );

    final shift = ActiveDriverShift.restore(
      id: 'shift-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      startedAt: startedAt,
      queueState: queueState,
    );

    expect(shift.id, 'shift-001');
    expect(shift.driverId, 'driver-001');
    expect(shift.vehicleId, 'vehicle-001');
    expect(shift.queueState.shortBreaksUsed, 1);
  });

  test('rejects queue state for another driver', () {
    final queueState = DriverQueueState.restore(
      driverId: 'driver-002',
      queuePrioritySince: startedAt,
      availability: DriverQueueAvailability.available,
      shortBreaksUsed: 0,
      breakStartedAt: null,
      hasPendingOffer: false,
    );

    expect(
      () => ActiveDriverShift.restore(
        id: 'shift-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        startedAt: startedAt,
        queueState: queueState,
      ),
      throwsArgumentError,
    );
  });
}

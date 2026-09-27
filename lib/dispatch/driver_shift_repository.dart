import 'active_driver_shift.dart';
import 'driver_queue_state.dart';

abstract interface class DriverShiftRepository {
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId);

  Future<List<ActiveDriverShift>> findAllActive();

  Future<ActiveDriverShift> startShift({
    required String shiftId,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
  });

  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  });

  Future<void> endShift({required String shiftId, required DateTime endedAt});
}

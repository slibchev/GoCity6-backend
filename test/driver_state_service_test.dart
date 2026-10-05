import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_state_service.dart';
import 'package:gocity6_backend/dispatch/driver_work_state_repository.dart';
import 'package:test/test.dart';

void main() {
  final startedAt = DateTime.utc(2026, 10, 5, 18);

  test('returns active shift when driver is working', () async {
    final activeShift = _buildShift(
      id: 'shift-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      startedAt: startedAt,
    );

    final service = DriverStateService(
      repository: _FakeDriverWorkStateRepository(
        snapshot: DriverWorkStateSnapshot(
          activeShift: activeShift,
          pendingOffer: null,
          currentRide: null,
          reservedRide: null,
        ),
      ),
    );

    final state = await service.load(
      driverId: 'driver-001',
    );

    expect(state.isWorking, isTrue);
    expect(state.activeShift, isNotNull);
    expect(state.activeShift!.id, 'shift-001');
    expect(state.activeShift!.vehicleId, 'vehicle-001');
    expect(
      state.activeShift!.queueState.availability,
      DriverQueueAvailability.available,
    );
  });

  test('returns no active shift when driver is not working', () async {
    final service = DriverStateService(
      repository: _FakeDriverWorkStateRepository(
        snapshot: const DriverWorkStateSnapshot(
          activeShift: null,
          pendingOffer: null,
          currentRide: null,
          reservedRide: null,
        ),
      ),
    );

    final state = await service.load(
      driverId: 'driver-001',
    );

    expect(state.isWorking, isFalse);
    expect(state.activeShift, isNull);
    expect(state.pendingOffer, isNull);
    expect(state.currentRide, isNull);
    expect(state.reservedRide, isNull);
  });
}

ActiveDriverShift _buildShift({
  required String id,
  required String driverId,
  required String vehicleId,
  required DateTime startedAt,
}) {
  final queueState = DriverQueueState.restore(
    driverId: driverId,
    queuePrioritySince: startedAt,
    availability: DriverQueueAvailability.available,
    shortBreaksUsed: 0,
    breakStartedAt: null,
    hasPendingOffer: false,
  );

  return ActiveDriverShift.restore(
    id: id,
    driverId: driverId,
    vehicleId: vehicleId,
    startedAt: startedAt,
    queueState: queueState,
  );
}

class _FakeDriverWorkStateRepository
    implements DriverWorkStateRepository {
  const _FakeDriverWorkStateRepository({
    required this.snapshot,
  });

  final DriverWorkStateSnapshot snapshot;

  @override
  Future<DriverWorkStateSnapshot> loadByDriverId(
    String driverId,
  ) async {
    return snapshot;
  }
}
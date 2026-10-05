import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/driver_state_service.dart';
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
      shiftRepository: _FakeDriverShiftRepository(
        activeShift: activeShift,
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
      shiftRepository: _FakeDriverShiftRepository(),
    );

    final state = await service.load(
      driverId: 'driver-001',
    );

    expect(state.isWorking, isFalse);
    expect(state.activeShift, isNull);
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

class _FakeDriverShiftRepository implements DriverShiftRepository {
  _FakeDriverShiftRepository({
    this.activeShift,
  });

  final ActiveDriverShift? activeShift;

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(
    String driverId,
  ) async {
    return activeShift;
  }

  @override
  Future<List<ActiveDriverShift>> findAllActive() async {
    return [
      if (activeShift != null) activeShift!,
    ];
  }

  @override
  Future<ActiveDriverShift> startShift({
    required String shiftId,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> endShift({
    required String shiftId,
    required DateTime endedAt,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }
}
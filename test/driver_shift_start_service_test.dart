import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_assigned_vehicle_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/driver_shift_start_service.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 4, 20);

  test('starts shift with assigned active vehicle', () async {
    final shiftRepository = _FakeDriverShiftRepository();

    final vehicleRepository = _FakeAssignedVehicleRepository(
      vehicle: const DriverAssignedVehicle(
        id: 'vehicle-001',
        plateNumber: 'CB1234AB',
        isActive: true,
      ),
    );

    final service = DriverShiftStartService(
      shiftRepository: shiftRepository,
      assignedVehicleRepository: vehicleRepository,
      shiftIdFactory: () => 'shift-new',
      now: () => now,
    );

    final shift = await service.start(
      driverId: 'driver-001',
    );

    expect(shift.id, 'shift-new');
    expect(shift.driverId, 'driver-001');
    expect(shift.vehicleId, 'vehicle-001');
    expect(
      shift.queueState.availability,
      DriverQueueAvailability.available,
    );
    expect(shiftRepository.startCalls, 1);
  });

  test('rejects driver without assigned vehicle', () async {
    final shiftRepository = _FakeDriverShiftRepository();

    final service = DriverShiftStartService(
      shiftRepository: shiftRepository,
      assignedVehicleRepository: _FakeAssignedVehicleRepository(),
      shiftIdFactory: () => 'shift-new',
      now: () => now,
    );

    expect(
      service.start(driverId: 'driver-001'),
      throwsA(
        isA<DriverShiftStartException>().having(
          (error) => error.failure,
          'failure',
          DriverShiftStartFailure.noAssignedVehicle,
        ),
      ),
    );

    expect(shiftRepository.startCalls, 0);
  });

  test('rejects inactive assigned vehicle', () async {
    final shiftRepository = _FakeDriverShiftRepository();

    final service = DriverShiftStartService(
      shiftRepository: shiftRepository,
      assignedVehicleRepository: _FakeAssignedVehicleRepository(
        vehicle: const DriverAssignedVehicle(
          id: 'vehicle-001',
          plateNumber: 'CB1234AB',
          isActive: false,
        ),
      ),
      shiftIdFactory: () => 'shift-new',
      now: () => now,
    );

    expect(
      service.start(driverId: 'driver-001'),
      throwsA(
        isA<DriverShiftStartException>().having(
          (error) => error.failure,
          'failure',
          DriverShiftStartFailure.assignedVehicleInactive,
        ),
      ),
    );

    expect(shiftRepository.startCalls, 0);
  });

  test('returns existing active shift instead of starting another', () async {
    final existingShift = _buildShift(
      id: 'shift-existing',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      startedAt: now,
    );

    final shiftRepository = _FakeDriverShiftRepository(
      activeShift: existingShift,
    );

    final vehicleRepository = _FakeAssignedVehicleRepository();

    final service = DriverShiftStartService(
      shiftRepository: shiftRepository,
      assignedVehicleRepository: vehicleRepository,
      shiftIdFactory: () => 'shift-new',
      now: () => now,
    );

    final result = await service.start(
      driverId: 'driver-001',
    );

    expect(result.id, 'shift-existing');
    expect(shiftRepository.startCalls, 0);
    expect(vehicleRepository.findCalls, 0);
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

class _FakeAssignedVehicleRepository
    implements DriverAssignedVehicleRepository {
  _FakeAssignedVehicleRepository({
    this.vehicle,
  });

  final DriverAssignedVehicle? vehicle;

  int findCalls = 0;

  @override
  Future<DriverAssignedVehicle?> findByDriverId(
    String driverId,
  ) async {
    findCalls += 1;
    return vehicle;
  }
}

class _FakeDriverShiftRepository implements DriverShiftRepository {
  _FakeDriverShiftRepository({
    this.activeShift,
  });

  ActiveDriverShift? activeShift;

  int startCalls = 0;

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
  }) async {
    startCalls += 1;

    final shift = _buildShift(
      id: shiftId,
      driverId: driverId,
      vehicleId: vehicleId,
      startedAt: startedAt,
    );

    activeShift = shift;
    return shift;
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
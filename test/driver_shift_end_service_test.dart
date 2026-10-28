import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_policy_service.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_end_service.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 13, 18);

  test('ends active shift and schedules penalty reset', () async {
    final shiftRepository = _FakeDriverShiftRepository(
      activeShift: _buildShift(
        id: 'shift-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        startedAt: now.subtract(const Duration(hours: 4)),
      ),
    );

    final dispatchStateRepository = _FakeDriverDispatchStateRepository(
      initialState: const DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 2,
        penaltyLevel: 1,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      ),
    );

    final service = DriverShiftEndService(
      shiftRepository: shiftRepository,
      dispatchPolicyService: DriverDispatchPolicyService(
        repository: dispatchStateRepository,
      ),
      now: () => now,
    );

    final endedAt = await service.end(driverId: 'driver-001');

    expect(endedAt, now);
    expect(shiftRepository.endCalls, 1);
    expect(shiftRepository.lastEndedShiftId, 'shift-001');
    expect(shiftRepository.lastEndedAt, now);
    expect(
      dispatchStateRepository.state?.penaltyResetEligibleAt,
      now.add(const Duration(hours: 8)),
    );
  });
  test('rejects end when driver has no active shift', () async {
    final shiftRepository = _FakeDriverShiftRepository();

    final dispatchStateRepository = _FakeDriverDispatchStateRepository(
      initialState: const DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 2,
        penaltyLevel: 1,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      ),
    );

    final service = DriverShiftEndService(
      shiftRepository: shiftRepository,
      dispatchPolicyService: DriverDispatchPolicyService(
        repository: dispatchStateRepository,
      ),
      now: () => now,
    );

    expect(
      service.end(driverId: 'driver-001'),
      throwsA(
        isA<DriverShiftEndException>().having(
          (error) => error.failure,
          'failure',
          DriverShiftEndFailure.noActiveShift,
        ),
      ),
    );

    expect(shiftRepository.endCalls, 0);
    expect(dispatchStateRepository.state?.penaltyResetEligibleAt, isNull);
  });

  test('does not end a shift with a scheduled after-ride break', () async {
    final shiftRepository =
        _FakeDriverShiftRepository(
            activeShift: _buildShift(
              id: 'shift-001',
              driverId: 'driver-001',
              vehicleId: 'vehicle-001',
              startedAt: now.subtract(const Duration(hours: 4)),
            ),
          )
          ..endConflict = const DriverShiftEndConflictException(
            DriverShiftEndConflict.pendingBreakScheduled,
          );
    final dispatchStateRepository = _FakeDriverDispatchStateRepository(
      initialState: const DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 0,
        penaltyLevel: 0,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      ),
    );
    final service = DriverShiftEndService(
      shiftRepository: shiftRepository,
      dispatchPolicyService: DriverDispatchPolicyService(
        repository: dispatchStateRepository,
      ),
      now: () => now,
    );

    await expectLater(
      service.end(driverId: 'driver-001'),
      throwsA(
        isA<DriverShiftEndException>().having(
          (error) => error.failure,
          'failure',
          DriverShiftEndFailure.pendingBreakScheduled,
        ),
      ),
    );
    expect(shiftRepository.endCalls, 0);
    expect(dispatchStateRepository.state?.penaltyResetEligibleAt, isNull);
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

class _FakeDriverDispatchStateRepository
    implements DriverDispatchStateRepository {
  _FakeDriverDispatchStateRepository({DriverDispatchState? initialState})
    : state = initialState;

  DriverDispatchState? state;

  @override
  Future<DriverDispatchState?> findByDriverId(String driverId) async {
    return state;
  }

  @override
  Future<DriverDispatchState> save(DriverDispatchState state) async {
    this.state = state;
    return state;
  }

  @override
  Future<DriverDispatchState> updateAtomically({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  }) async {
    final current =
        state ??
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: 0,
          dispatchBlockedUntil: null,
          penaltyResetEligibleAt: null,
        );

    final next = transform(current);
    state = next;
    return next;
  }
}

class _FakeDriverShiftRepository implements DriverShiftRepository {
  _FakeDriverShiftRepository({this.activeShift});

  ActiveDriverShift? activeShift;

  int endCalls = 0;
  DriverShiftEndConflictException? endConflict;
  String? lastEndedShiftId;
  DateTime? lastEndedAt;

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async {
    return activeShift;
  }

  @override
  Future<void> endShift({
    required String shiftId,
    required DateTime endedAt,
  }) async {
    if (endConflict != null) throw endConflict!;
    endCalls += 1;
    lastEndedShiftId = shiftId;
    lastEndedAt = endedAt;
    activeShift = null;
  }

  @override
  Future<List<ActiveDriverShift>> findAllActive() async {
    return [?activeShift];
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
}

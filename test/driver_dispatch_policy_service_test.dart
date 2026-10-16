import 'package:gocity6_backend/dispatch/driver_dispatch_policy_service.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state_repository.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 13, 12);

  test('first two rejects do not block driver', () async {
    final repository = _FakeDriverDispatchStateRepository();
    final service = DriverDispatchPolicyService(repository: repository);

    final first = await service.recordRejectedOffer(
      driverId: 'driver-001',
      now: now,
    );

    final second = await service.recordRejectedOffer(
      driverId: 'driver-001',
      now: now,
    );

    expect(first.consecutiveRejects, 1);
    expect(second.consecutiveRejects, 2);
    expect(second.penaltyLevel, 0);
    expect(second.dispatchBlockedUntil, isNull);
  });

  test('third consecutive reject blocks driver for 30 minutes', () async {
    final repository = _FakeDriverDispatchStateRepository();
    final service = DriverDispatchPolicyService(repository: repository);

    await service.recordRejectedOffer(driverId: 'driver-001', now: now);

    await service.recordRejectedOffer(driverId: 'driver-001', now: now);

    final third = await service.recordRejectedOffer(
      driverId: 'driver-001',
      now: now,
    );

    expect(third.consecutiveRejects, 0);
    expect(third.penaltyLevel, 1);
    expect(third.dispatchBlockedUntil, now.add(const Duration(minutes: 30)));
  });

  test('completed ride resets consecutive rejects', () async {
    final repository = _FakeDriverDispatchStateRepository(
      initialState: const DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 2,
        penaltyLevel: 1,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      ),
    );

    final service = DriverDispatchPolicyService(repository: repository);

    final result = await service.recordCompletedRide(driverId: 'driver-001');

    expect(result.consecutiveRejects, 0);
    expect(result.penaltyLevel, 1);
  });
  test(
    'rejecting bonus offer blocks driver immediately for 30 minutes',
    () async {
      final repository = _FakeDriverDispatchStateRepository(
        initialState: const DriverDispatchState(
          driverId: 'driver-001',
          consecutiveRejects: 2,
          penaltyLevel: 1,
          dispatchBlockedUntil: null,
          penaltyResetEligibleAt: null,
        ),
      );

      final service = DriverDispatchPolicyService(repository: repository);

      final result = await service.recordRejectedBonusOffer(
        driverId: 'driver-001',
        now: now,
      );

      expect(result.consecutiveRejects, 0);
      expect(result.penaltyLevel, 1);
      expect(result.dispatchBlockedUntil, now.add(const Duration(minutes: 30)));
    },
  );
  test('ending shift schedules penalty reset after 8 hours', () async {
    final repository = _FakeDriverDispatchStateRepository(
      initialState: const DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 2,
        penaltyLevel: 3,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      ),
    );

    final service = DriverDispatchPolicyService(repository: repository);

    final result = await service.recordShiftEnded(
      driverId: 'driver-001',
      endedAt: now,
    );

    expect(result.consecutiveRejects, 2);
    expect(result.penaltyLevel, 3);
    expect(result.penaltyResetEligibleAt, now.add(const Duration(hours: 8)));
  });
  test('starting shift before 8 hours preserves penalty state', () async {
    final resetEligibleAt = now.add(const Duration(hours: 8));

    final repository = _FakeDriverDispatchStateRepository(
      initialState: DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 2,
        penaltyLevel: 3,
        dispatchBlockedUntil: now.add(const Duration(minutes: 45)),
        penaltyResetEligibleAt: resetEligibleAt,
      ),
    );

    final service = DriverDispatchPolicyService(repository: repository);

    final result = await service.recordShiftStarted(
      driverId: 'driver-001',
      startedAt: now.add(const Duration(hours: 7)),
    );

    expect(result.consecutiveRejects, 2);
    expect(result.penaltyLevel, 3);
    expect(result.dispatchBlockedUntil, now.add(const Duration(minutes: 45)));
    expect(result.penaltyResetEligibleAt, isNull);
  });
  test('starting shift after 8 hours resets penalty state', () async {
    final resetEligibleAt = now.add(const Duration(hours: 8));

    final repository = _FakeDriverDispatchStateRepository(
      initialState: DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 2,
        penaltyLevel: 3,
        dispatchBlockedUntil: now.add(const Duration(hours: 2)),
        penaltyResetEligibleAt: resetEligibleAt,
      ),
    );

    final service = DriverDispatchPolicyService(repository: repository);

    final result = await service.recordShiftStarted(
      driverId: 'driver-001',
      startedAt: resetEligibleAt,
    );

    expect(result.consecutiveRejects, 0);
    expect(result.penaltyLevel, 0);
    expect(result.dispatchBlockedUntil, isNull);
    expect(result.penaltyResetEligibleAt, isNull);
  });
  test('next three rejects increase penalty to 60 minutes', () async {
    final repository = _FakeDriverDispatchStateRepository(
      initialState: DriverDispatchState(
        driverId: 'driver-001',
        consecutiveRejects: 0,
        penaltyLevel: 1,
        dispatchBlockedUntil: now.subtract(const Duration(minutes: 1)),
        penaltyResetEligibleAt: null,
      ),
    );

    final service = DriverDispatchPolicyService(repository: repository);

    await service.recordRejectedOffer(driverId: 'driver-001', now: now);

    await service.recordRejectedOffer(driverId: 'driver-001', now: now);

    final third = await service.recordRejectedOffer(
      driverId: 'driver-001',
      now: now,
    );

    expect(third.consecutiveRejects, 0);
    expect(third.penaltyLevel, 2);
    expect(third.dispatchBlockedUntil, now.add(const Duration(minutes: 60)));
  });
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

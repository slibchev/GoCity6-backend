import 'package:test/test.dart';
import 'package:gocity6_backend/admin/test_driver_penalty_admin.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';

void main() {
  test(
    'test penalty admin allowlist is limited to the two authorized drivers',
    () {
      expect(TestDriverPenaltyAdmin.allowedDriverIds, {
        'driver-e2e-001',
        'driver-city6-test-2-48966f02-c34b-4c4c-9ca3-f0411d5ea457',
      });
    },
  );

  final resetAt = DateTime.utc(2026, 10, 25, 12);

  DriverDispatchState state() => DriverDispatchState(
    driverId: 'driver-e2e-001',
    consecutiveRejects: 2,
    penaltyLevel: 4,
    dispatchBlockedUntil: resetAt,
    penaltyResetEligibleAt: resetAt.add(const Duration(hours: 8)),
    requiresCompletedRideAfterPenalty: true,
  );

  test('unblock clears only the active time block', () {
    final result = TestDriverPenaltyAdmin.apply(
      state(),
      TestDriverPenaltyAction.unblock,
    );

    expect(result.dispatchBlockedUntil, isNull);
    expect(result.consecutiveRejects, 2);
    expect(result.penaltyLevel, 4);
    expect(
      result.penaltyResetEligibleAt,
      resetAt.add(const Duration(hours: 8)),
    );
    expect(result.requiresCompletedRideAfterPenalty, isTrue);
  });

  test('full reset clears all accumulated and active penalty state', () {
    final result = TestDriverPenaltyAdmin.apply(
      state(),
      TestDriverPenaltyAction.fullReset,
    );

    expect(result.consecutiveRejects, 0);
    expect(result.penaltyLevel, 0);
    expect(result.dispatchBlockedUntil, isNull);
    expect(result.penaltyResetEligibleAt, isNull);
    expect(result.requiresCompletedRideAfterPenalty, isFalse);
  });
}

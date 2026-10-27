import '../dispatch/driver_dispatch_state.dart';

enum TestDriverPenaltyAction { unblock, fullReset }

class TestDriverPenaltyAdmin {
  static const allowedDriverIds = {
    'driver-e2e-001',
    'driver-city6-test-2-48966f02-c34b-4c4c-9ca3-f0411d5ea457',
  };

  static DriverDispatchState apply(
    DriverDispatchState current,
    TestDriverPenaltyAction action,
  ) {
    return switch (action) {
      TestDriverPenaltyAction.unblock => DriverDispatchState(
        driverId: current.driverId,
        consecutiveRejects: current.consecutiveRejects,
        penaltyLevel: current.penaltyLevel,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: current.penaltyResetEligibleAt,
        requiresCompletedRideAfterPenalty:
            current.requiresCompletedRideAfterPenalty,
      ),
      TestDriverPenaltyAction.fullReset => DriverDispatchState(
        driverId: current.driverId,
        consecutiveRejects: 0,
        penaltyLevel: 0,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
        requiresCompletedRideAfterPenalty: false,
      ),
    };
  }
}

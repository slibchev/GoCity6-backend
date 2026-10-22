import 'driver_dispatch_state.dart';
import 'driver_dispatch_state_repository.dart';

class DriverDispatchPolicyService {
  static const int maxConsecutiveRejects = 3;
  static const Duration penaltyStep = Duration(minutes: 30);
  static const Duration penaltyResetDelay = Duration(hours: 8);
  static const Duration penaltyEligibilityWindow = Duration(minutes: 20);

  static bool isOfferPenaltyEligible({
    required DateTime requestedAt,
    required DateTime offeredAt,
  }) {
    final age = offeredAt.toUtc().difference(requestedAt.toUtc());

    return !age.isNegative && age < penaltyEligibilityWindow;
  }

  /// Applies the shared transition for explicit and ignored standard offers.
  /// [rejectedAt] is the driver's rejection time or the ignored offer's expiry.
  static DriverDispatchState afterStandardOfferRejection({
    required DriverDispatchState current,
    required DateTime rejectedAt,
  }) {
    final rejectedAtUtc = rejectedAt.toUtc();

    if (current.requiresCompletedRideAfterPenalty &&
        !current.isBlockedAt(rejectedAtUtc)) {
      return _applyStandardPenalty(
        current: current,
        penaltyStartedAt: rejectedAtUtc,
      );
    }

    final nextRejectCount = current.consecutiveRejects + 1;

    if (nextRejectCount < maxConsecutiveRejects) {
      return DriverDispatchState(
        driverId: current.driverId,
        consecutiveRejects: nextRejectCount,
        penaltyLevel: current.penaltyLevel,
        dispatchBlockedUntil: current.dispatchBlockedUntil,
        penaltyResetEligibleAt: current.penaltyResetEligibleAt,
        requiresCompletedRideAfterPenalty:
            current.requiresCompletedRideAfterPenalty,
      );
    }

    return _applyStandardPenalty(
      current: current,
      penaltyStartedAt: rejectedAtUtc,
    );
  }

  static DriverDispatchState _applyStandardPenalty({
    required DriverDispatchState current,
    required DateTime penaltyStartedAt,
  }) {
    final nextPenaltyLevel = current.penaltyLevel + 1;
    final penaltyDuration = Duration(
      minutes: penaltyStep.inMinutes * nextPenaltyLevel,
    );

    return DriverDispatchState(
      driverId: current.driverId,
      consecutiveRejects: 0,
      penaltyLevel: nextPenaltyLevel,
      dispatchBlockedUntil: penaltyStartedAt.add(penaltyDuration),
      penaltyResetEligibleAt: current.penaltyResetEligibleAt,
      requiresCompletedRideAfterPenalty: true,
    );
  }

  /// Bonus offers keep their existing immediate fixed cooldown semantics.
  static DriverDispatchState afterBonusOfferRejection({
    required DriverDispatchState current,
    required DateTime rejectedAt,
  }) {
    return DriverDispatchState(
      driverId: current.driverId,
      consecutiveRejects: 0,
      penaltyLevel: current.penaltyLevel,
      dispatchBlockedUntil: rejectedAt.toUtc().add(penaltyStep),
      penaltyResetEligibleAt: current.penaltyResetEligibleAt,
      requiresCompletedRideAfterPenalty:
          current.requiresCompletedRideAfterPenalty,
    );
  }

  static DriverDispatchState afterCompletedRide({
    required DriverDispatchState current,
  }) {
    return DriverDispatchState(
      driverId: current.driverId,
      consecutiveRejects: 0,
      penaltyLevel: current.penaltyLevel,
      dispatchBlockedUntil: current.dispatchBlockedUntil,
      penaltyResetEligibleAt: current.penaltyResetEligibleAt,
      requiresCompletedRideAfterPenalty: false,
    );
  }

  final DriverDispatchStateRepository repository;

  const DriverDispatchPolicyService({required this.repository});

  Future<DriverDispatchState> recordRejectedOffer({
    required String driverId,
    required DateTime now,
  }) {
    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) =>
          afterStandardOfferRejection(current: current, rejectedAt: now),
    );
  }

  Future<DriverDispatchState> recordRejectedBonusOffer({
    required String driverId,
    required DateTime now,
  }) {
    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) =>
          afterBonusOfferRejection(current: current, rejectedAt: now),
    );
  }

  Future<DriverDispatchState> recordCompletedRide({required String driverId}) {
    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) => afterCompletedRide(current: current),
    );
  }

  Future<DriverDispatchState> recordShiftEnded({
    required String driverId,
    required DateTime endedAt,
  }) {
    final endedAtUtc = endedAt.toUtc();

    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) {
        return DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: current.consecutiveRejects,
          penaltyLevel: current.penaltyLevel,
          dispatchBlockedUntil: current.dispatchBlockedUntil,
          penaltyResetEligibleAt: endedAtUtc.add(penaltyResetDelay),
          requiresCompletedRideAfterPenalty:
              current.requiresCompletedRideAfterPenalty,
        );
      },
    );
  }

  Future<DriverDispatchState> recordShiftStarted({
    required String driverId,
    required DateTime startedAt,
  }) {
    final startedAtUtc = startedAt.toUtc();

    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) {
        final resetEligibleAt = current.penaltyResetEligibleAt;

        if (resetEligibleAt != null &&
            !startedAtUtc.isBefore(resetEligibleAt.toUtc())) {
          return DriverDispatchState(
            driverId: driverId,
            consecutiveRejects: 0,
            penaltyLevel: 0,
            dispatchBlockedUntil: null,
            penaltyResetEligibleAt: null,
            requiresCompletedRideAfterPenalty: false,
          );
        }

        return DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: current.consecutiveRejects,
          penaltyLevel: current.penaltyLevel,
          dispatchBlockedUntil: current.dispatchBlockedUntil,
          penaltyResetEligibleAt: null,
          requiresCompletedRideAfterPenalty:
              current.requiresCompletedRideAfterPenalty,
        );
      },
    );
  }
}

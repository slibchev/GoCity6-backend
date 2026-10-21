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

  final DriverDispatchStateRepository repository;

  const DriverDispatchPolicyService({required this.repository});

  Future<DriverDispatchState> recordRejectedOffer({
    required String driverId,
    required DateTime now,
  }) {
    final nowUtc = now.toUtc();

    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) {
        final nextRejectCount = current.consecutiveRejects + 1;

        if (nextRejectCount < maxConsecutiveRejects) {
          return DriverDispatchState(
            driverId: driverId,
            consecutiveRejects: nextRejectCount,
            penaltyLevel: current.penaltyLevel,
            dispatchBlockedUntil: current.dispatchBlockedUntil,
            penaltyResetEligibleAt: current.penaltyResetEligibleAt,
          );
        }

        final nextPenaltyLevel = current.penaltyLevel + 1;
        final penaltyDuration = Duration(
          minutes: penaltyStep.inMinutes * nextPenaltyLevel,
        );

        return DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: nextPenaltyLevel,
          dispatchBlockedUntil: nowUtc.add(penaltyDuration),
          penaltyResetEligibleAt: current.penaltyResetEligibleAt,
        );
      },
    );
  }

  Future<DriverDispatchState> recordRejectedBonusOffer({
    required String driverId,
    required DateTime now,
  }) {
    final nowUtc = now.toUtc();

    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) {
        return DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: current.penaltyLevel,
          dispatchBlockedUntil: nowUtc.add(penaltyStep),
          penaltyResetEligibleAt: current.penaltyResetEligibleAt,
        );
      },
    );
  }

  Future<DriverDispatchState> recordCompletedRide({required String driverId}) {
    return repository.updateAtomically(
      driverId: driverId,
      transform: (current) {
        return DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: current.penaltyLevel,
          dispatchBlockedUntil: current.dispatchBlockedUntil,
          penaltyResetEligibleAt: current.penaltyResetEligibleAt,
        );
      },
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
          );
        }

        return DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: current.consecutiveRejects,
          penaltyLevel: current.penaltyLevel,
          dispatchBlockedUntil: current.dispatchBlockedUntil,
          penaltyResetEligibleAt: null,
        );
      },
    );
  }
}

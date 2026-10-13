import 'driver_dispatch_state.dart';
import 'driver_dispatch_state_repository.dart';

class DriverDispatchPolicyService {
  static const int maxConsecutiveRejects = 3;
  static const Duration penaltyStep = Duration(minutes: 30);

  final DriverDispatchStateRepository repository;

  const DriverDispatchPolicyService({required this.repository});

  Future<DriverDispatchState> recordRejectedOffer({
    required String driverId,
    required DateTime now,
  }) async {
    final nowUtc = now.toUtc();

    final current =
        await repository.findByDriverId(driverId) ??
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: 0,
          dispatchBlockedUntil: null,
          penaltyResetEligibleAt: null,
        );

    final nextRejectCount = current.consecutiveRejects + 1;

    if (nextRejectCount < maxConsecutiveRejects) {
      return repository.save(
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: nextRejectCount,
          penaltyLevel: current.penaltyLevel,
          dispatchBlockedUntil: current.dispatchBlockedUntil,
          penaltyResetEligibleAt: current.penaltyResetEligibleAt,
        ),
      );
    }

    final nextPenaltyLevel = current.penaltyLevel + 1;
    final penaltyDuration = Duration(
      minutes: penaltyStep.inMinutes * nextPenaltyLevel,
    );

    return repository.save(
      DriverDispatchState(
        driverId: driverId,
        consecutiveRejects: 0,
        penaltyLevel: nextPenaltyLevel,
        dispatchBlockedUntil: nowUtc.add(penaltyDuration),
        penaltyResetEligibleAt: current.penaltyResetEligibleAt,
      ),
    );
  }

  Future<DriverDispatchState> recordRejectedBonusOffer({
    required String driverId,
    required DateTime now,
  }) async {
    final nowUtc = now.toUtc();

    final current =
        await repository.findByDriverId(driverId) ??
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: 0,
          dispatchBlockedUntil: null,
          penaltyResetEligibleAt: null,
        );

    return repository.save(
      DriverDispatchState(
        driverId: driverId,
        consecutiveRejects: 0,
        penaltyLevel: current.penaltyLevel,
        dispatchBlockedUntil: nowUtc.add(const Duration(minutes: 30)),
        penaltyResetEligibleAt: current.penaltyResetEligibleAt,
      ),
    );
  }

  Future<DriverDispatchState> recordCompletedRide({
    required String driverId,
  }) async {
    final current =
        await repository.findByDriverId(driverId) ??
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: 0,
          dispatchBlockedUntil: null,
          penaltyResetEligibleAt: null,
        );

    return repository.save(
      DriverDispatchState(
        driverId: driverId,
        consecutiveRejects: 0,
        penaltyLevel: current.penaltyLevel,
        dispatchBlockedUntil: current.dispatchBlockedUntil,
        penaltyResetEligibleAt: current.penaltyResetEligibleAt,
      ),
    );
  }
}

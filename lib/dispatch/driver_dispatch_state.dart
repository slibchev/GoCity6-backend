class DriverDispatchState {
  final String driverId;
  final int consecutiveRejects;
  final int penaltyLevel;
  final DateTime? dispatchBlockedUntil;
  final DateTime? penaltyResetEligibleAt;

  const DriverDispatchState({
    required this.driverId,
    required this.consecutiveRejects,
    required this.penaltyLevel,
    required this.dispatchBlockedUntil,
    required this.penaltyResetEligibleAt,
  });

  bool isBlockedAt(DateTime now) {
    final blockedUntil = dispatchBlockedUntil;

    return blockedUntil != null &&
        now.toUtc().isBefore(blockedUntil.toUtc());
  }
}
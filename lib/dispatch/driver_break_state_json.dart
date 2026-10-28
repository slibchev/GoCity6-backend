import 'driver_queue_state.dart';

Map<String, Object?> driverBreakStateJson(
  DriverQueueState queueState, {
  required DateTime now,
}) {
  final nowUtc = now.toUtc();
  final shortBreakStartedAt =
      queueState.availability == DriverQueueAvailability.shortBreak
      ? queueState.breakStartedAt
      : null;
  final expiresAt = shortBreakStartedAt?.add(
    DriverQueueState.shortBreakDuration,
  );
  final remainingSeconds = expiresAt
      ?.difference(nowUtc)
      .inSeconds
      .clamp(0, 600)
      .toInt();

  final mode = switch (queueState.availability) {
    DriverQueueAvailability.shortBreak => 'short',
    DriverQueueAvailability.longBreak => 'long',
    _ => 'none',
  };

  return {
    'mode': mode,
    'startedAt': queueState.breakStartedAt?.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'remainingSeconds': remainingSeconds,
    'shortBreaksUsed': queueState.shortBreaksUsed,
    'shortBreaksRemaining': queueState.shortBreaksRemaining,
    'maxShortBreaksPerShift': DriverQueueState.maxShortBreaksPerShift,
  };
}

Map<String, Object?>? pendingDriverBreakStateJson({
  required String? kind,
  required String? requestId,
  required DateTime? requestedAt,
}) {
  if (kind == null) return null;
  return {
    'kind': kind,
    'status': 'pending',
    'activation': 'afterCurrentRide',
    'requestId': requestId,
    'requestedAt': requestedAt?.toUtc().toIso8601String(),
  };
}

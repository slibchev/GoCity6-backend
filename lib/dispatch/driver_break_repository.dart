import 'active_driver_shift.dart';

enum DriverBreakKind { short, long }

enum DriverBreakConflict {
  activeShiftNotFound,
  notAvailable,
  activeOffer,
  currentRide,
  reservedRide,
  noShortBreaksRemaining,
  notOnBreak,
  pendingBreakConflict,
  pendingBreakNotFound,
  breakAlreadyActivated,
  idempotencyKeyReused,
  idempotencyKeyRequired,
}

enum DriverBreakRequestStatus { pending, active, completed, cancelled }

class DriverBreakOperationResult {
  final ActiveDriverShift shift;
  final DriverBreakKind? pendingBreakKind;
  final String? pendingBreakRequestId;
  final DateTime? pendingBreakRequestedAt;
  final String? activeBreakRequestId;
  final DriverBreakRequestStatus? requestStatus;
  final bool replayed;
  final String? requestId;
  final DriverBreakKind? requestKind;

  const DriverBreakOperationResult({
    required this.shift,
    required this.pendingBreakKind,
    required this.pendingBreakRequestId,
    this.pendingBreakRequestedAt,
    required this.activeBreakRequestId,
    required this.requestStatus,
    this.replayed = false,
    this.requestId,
    this.requestKind,
  });
}

class DriverBreakConflictException implements Exception {
  final DriverBreakConflict conflict;

  const DriverBreakConflictException(this.conflict);

  @override
  String toString() => 'Driver break conflict: ${conflict.name}';
}

abstract interface class DriverBreakRepository {
  /// Starts immediately when available. A busy current ride may schedule a
  /// break only with a stable UUID [requestId] reused for retries.
  Future<DriverBreakOperationResult> startBreak({
    required String driverId,
    required DriverBreakKind kind,
    String? requestId,
  });

  Future<DriverBreakOperationResult> endBreak({required String driverId});

  Future<DriverBreakOperationResult> cancelPendingBreak({
    required String driverId,
    required String requestId,
  });
}

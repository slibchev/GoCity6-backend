import 'driver_break_repository.dart';

class DriverBreakService {
  final DriverBreakRepository repository;

  const DriverBreakService({required this.repository});

  Future<DriverBreakOperationResult> startShortBreak({
    required String driverId,
    String? requestId,
  }) {
    return repository.startBreak(
      driverId: driverId,
      kind: DriverBreakKind.short,
      requestId: requestId,
    );
  }

  Future<DriverBreakOperationResult> startLongBreak({
    required String driverId,
    String? requestId,
  }) {
    return repository.startBreak(
      driverId: driverId,
      kind: DriverBreakKind.long,
      requestId: requestId,
    );
  }

  Future<DriverBreakOperationResult> endBreak({required String driverId}) {
    return repository.endBreak(driverId: driverId);
  }

  Future<DriverBreakOperationResult> cancelPendingBreak({
    required String driverId,
    required String requestId,
  }) {
    return repository.cancelPendingBreak(
      driverId: driverId,
      requestId: requestId,
    );
  }
}

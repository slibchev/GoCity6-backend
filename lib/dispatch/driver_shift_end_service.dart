import 'driver_dispatch_policy_service.dart';
import 'driver_shift_repository.dart';

enum DriverShiftEndFailure { noActiveShift, pendingBreakScheduled }

class DriverShiftEndException implements Exception {
  final DriverShiftEndFailure failure;

  const DriverShiftEndException(this.failure);

  @override
  String toString() {
    return 'Driver shift end failed: ${failure.name}';
  }
}

class DriverShiftEndService {
  final DriverShiftRepository shiftRepository;
  final DriverDispatchPolicyService dispatchPolicyService;
  final DateTime Function() now;

  const DriverShiftEndService({
    required this.shiftRepository,
    required this.dispatchPolicyService,
    required this.now,
  });

  Future<DateTime> end({required String driverId}) async {
    final shift = await shiftRepository.findActiveByDriverId(driverId);

    if (shift == null) {
      throw const DriverShiftEndException(DriverShiftEndFailure.noActiveShift);
    }

    final endedAt = now().toUtc();

    try {
      await shiftRepository.endShift(shiftId: shift.id, endedAt: endedAt);
    } on DriverShiftEndConflictException catch (error) {
      if (error.conflict == DriverShiftEndConflict.pendingBreakScheduled) {
        throw const DriverShiftEndException(
          DriverShiftEndFailure.pendingBreakScheduled,
        );
      }
      rethrow;
    }

    await dispatchPolicyService.recordShiftEnded(
      driverId: driverId,
      endedAt: endedAt,
    );

    return endedAt;
  }
}

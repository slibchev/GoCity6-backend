import 'active_driver_shift.dart';
import 'driver_shift_repository.dart';

class DriverState {
  final ActiveDriverShift? activeShift;

  const DriverState({
    required this.activeShift,
  });

  bool get isWorking => activeShift != null;
}

class DriverStateService {
  final DriverShiftRepository shiftRepository;

  const DriverStateService({
    required this.shiftRepository,
  });

  Future<DriverState> load({
    required String driverId,
  }) async {
    final activeShift =
        await shiftRepository.findActiveByDriverId(driverId);

    return DriverState(
      activeShift: activeShift,
    );
  }
}
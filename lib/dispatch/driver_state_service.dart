import 'active_driver_shift.dart';
import 'driver_work_state_repository.dart';
import '../ride/ride_request.dart';

class DriverState {
  final DriverWorkStateSnapshot snapshot;

  const DriverState({required this.snapshot});

  ActiveDriverShift? get activeShift => snapshot.activeShift;

  DriverPendingOfferState? get pendingOffer => snapshot.pendingOffer;

  RideRequest? get currentRide => snapshot.currentRide;

  RideRequest? get reservedRide => snapshot.reservedRide;
  bool get isWorking => activeShift != null;
}

class DriverStateService {
  final DriverWorkStateRepository repository;

  const DriverStateService({required this.repository});

  Future<DriverState> load({required String driverId}) async {
    final snapshot = await repository.loadByDriverId(driverId);

    return DriverState(snapshot: snapshot);
  }
}

import 'driver_dispatch_state.dart';

abstract interface class DriverDispatchStateRepository {
  Future<DriverDispatchState?> findByDriverId(String driverId);

  Future<DriverDispatchState> save(DriverDispatchState state);

  Future<DriverDispatchState> updateAtomically({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  });
}